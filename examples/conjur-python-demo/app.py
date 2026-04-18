#!/usr/bin/env python3
import logging
import os
import sys
import time

from conjur_authn import get_access_token, get_variable, make_auth_header

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger(__name__)

CONJUR_URL = os.environ["CONJUR_APPLIANCE_URL"]
CONJUR_ACCOUNT = os.environ["CONJUR_ACCOUNT"]
CONJUR_AUTHN_URL = os.environ["CONJUR_AUTHN_URL"]
CONJUR_AUTHN_LOGIN = os.environ["CONJUR_AUTHN_LOGIN"]
CONJUR_SSL_CERT_FILE = os.environ.get("CONJUR_SSL_CERT_FILE", "/etc/conjur/ssl/ca.pem")

SECRETS = [
    "test-secretless-app-db/username",
    "test-secretless-app-db/password",
    "test-secretless-app-db/url",
    "test-secretless-app-db/port",
    "test-secretless-app-db/host",
]

ITERATIONS = 2000
INTERVAL_SECONDS = 10


def run_iteration(iteration: int) -> None:
    logger.info("=== Iteration %d/%d ===", iteration, ITERATIONS)

    raw_token = get_access_token(
        authn_url=CONJUR_AUTHN_URL,
        account=CONJUR_ACCOUNT,
        login=CONJUR_AUTHN_LOGIN,
        ssl_ca=CONJUR_SSL_CERT_FILE,
    )
    logger.info("Access token received (first 60 chars): %s...", raw_token[:60])

    auth_header = make_auth_header(raw_token)

    for var_id in SECRETS:
        value = get_variable(
            conjur_url=CONJUR_URL,
            account=CONJUR_ACCOUNT,
            variable_id=var_id,
            auth_header=auth_header,
            ssl_ca=CONJUR_SSL_CERT_FILE,
        )
        logger.info("  %s = %s", var_id, value)


def main() -> None:
    for i in range(1, ITERATIONS + 1):
        run_iteration(i)
        if i < ITERATIONS:
            logger.info("Sleeping %ds before next iteration...", INTERVAL_SECONDS)
            time.sleep(INTERVAL_SECONDS)
    logger.info("All %d iterations complete.", ITERATIONS)


if __name__ == "__main__":
    main()
