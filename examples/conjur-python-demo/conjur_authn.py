import base64
import logging
import os
import time
from pathlib import Path

import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

logger = logging.getLogger(__name__)

_K8S_SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
_CLIENT_CERT_PATH = "/etc/conjur/ssl/client.pem"
_CLIENT_KEY_PATH = "/tmp/conjur-private.pem"
_CERT_INJECT_TIMEOUT = 60


def _build_spiffe_uri() -> str:
    namespace = os.environ.get("MY_POD_NAMESPACE", "app-test")
    pod_name = os.environ["MY_POD_NAME"]
    return f"spiffe://cluster.local/namespace/{namespace}/pod/{pod_name}"


def get_access_token(authn_url: str, account: str, login: str, ssl_ca: str = None) -> str:
    spiffe_uri = _build_spiffe_uri()

    # Conjur prepends "host.conjur.authn-k8s.<service_id>.apps" to the CN.
    # The CSR CN must be just the short host name (last segment of the login path).
    csr_cn = login.rstrip("/").split("/")[-1]

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, csr_cn)]))
        .add_extension(
            x509.SubjectAlternativeName([x509.UniformResourceIdentifier(spiffe_uri)]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM)

    # Remove stale cert so we can detect when Conjur injects a fresh one
    cert_path = Path(_CLIENT_CERT_PATH)
    cert_path.unlink(missing_ok=True)

    logger.debug("Posting CSR to inject_client_cert (SPIFFE: %s)", spiffe_uri)
    resp = requests.post(
        f"{authn_url}/inject_client_cert",
        data=csr_pem,
        headers={"Content-Type": "text/plain"},
        verify=ssl_ca or False,
    )
    resp.raise_for_status()

    logger.debug("Waiting for Conjur to inject client certificate via kubectl exec")
    deadline = time.time() + _CERT_INJECT_TIMEOUT
    while time.time() < deadline:
        if cert_path.exists() and cert_path.stat().st_size > 0:
            break
        time.sleep(0.5)
    else:
        raise TimeoutError(f"Client certificate not injected within {_CERT_INJECT_TIMEOUT}s")

    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )
    Path(_CLIENT_KEY_PATH).write_bytes(key_pem)

    logger.debug("Authenticating with mutual TLS")
    login_encoded = requests.utils.quote(login, safe="")
    resp = requests.post(
        f"{authn_url}/{account}/{login_encoded}/authenticate",
        headers={"Content-Type": "text/plain"},
        cert=(_CLIENT_CERT_PATH, _CLIENT_KEY_PATH),
        verify=ssl_ca or False,
    )
    resp.raise_for_status()
    return resp.text


def make_auth_header(raw_token: str) -> str:
    encoded = base64.b64encode(raw_token.encode()).decode()
    return f'Token token="{encoded}"'


def get_variable(conjur_url: str, account: str, variable_id: str, auth_header: str, ssl_ca: str = None) -> str:
    encoded_id = requests.utils.quote(variable_id, safe="")
    resp = requests.get(
        f"{conjur_url}/secrets/{account}/variable/{encoded_id}",
        headers={"Authorization": auth_header},
        verify=ssl_ca or False,
    )
    resp.raise_for_status()
    return resp.text
