FROM python:3.11-slim

WORKDIR /app

RUN mkdir -p /etc/conjur/ssl /tmp

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY conjur_authn.py app.py ./

CMD ["python", "-u", "app.py"]
