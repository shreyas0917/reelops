#!/usr/bin/env python3
"""Redact owner-specific values from text that goes to public places (PR
comments, job summaries): the AWS account ID, the alert email and the
allowlisted IPs. The values come from the job environment (ACCT,
TF_VAR_alert_email, TF_VAR_allowed_cidrs), so none of them live in the repo.

GitHub masks secrets in logs, but not text posted through the API, and
allowed_cidrs is a variable, not a secret.

Usage: some_command | scripts/redact.py
"""

import json
import os
import sys

replacements = {}
if os.environ.get("ACCT"):
    replacements[os.environ["ACCT"]] = "<account-id>"
if os.environ.get("TF_VAR_alert_email"):
    replacements[os.environ["TF_VAR_alert_email"]] = "<alert-email>"
for cidr in json.loads(os.environ.get("TF_VAR_allowed_cidrs") or "[]"):
    replacements[cidr.split("/")[0]] = "<allowed-ip>"

text = sys.stdin.read()
for value in sorted(replacements, key=len, reverse=True):  # longest first
    text = text.replace(value, replacements[value])
sys.stdout.write(text)
