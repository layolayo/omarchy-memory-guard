#!/bin/bash
TOTAL=$(free | awk '/^Mem:/{print $2}')
USED=$(free | awk '/^Mem:/{print $3}')
PCT=$((USED * 100 / TOTAL))
exit $PCT
