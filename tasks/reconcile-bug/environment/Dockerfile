FROM python:3.12-slim

WORKDIR /app

# Make sure the verifier log directory exists even if Harbor doesn't create it.
RUN mkdir -p /logs/verifier

COPY reconcile.py /app/reconcile.py
