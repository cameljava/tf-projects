#!/bin/bash

INSTANCE_ID="i-0d393be06c9162476"

aws cloudwatch put-metric-data \
  --namespace "Custom/Test" \
  --metric-name "InstanceFailure" \
  --dimensions InstanceId=$INSTANCE_ID \
  --value 0

echo "Simulated failure cleared"