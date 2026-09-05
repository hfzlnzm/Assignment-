#!/usr/bin/env bash
if grep -rE "AKIA[0-9A-Z]{16}" . --include="*.py" --include="*.js" --include="*.sh" 2>/dev/null; then
  echo "BLOCKED: hardcoded credential pattern found"
  exit 1
fi
echo "No hardcoded credentials found"
exit 0
