#!/usr/bin/env bash
# MediPay technical evidence collection - IKB42603 - Member C
# Paste this whole block into the Codespaces terminal at once.
set -uo pipefail

### 1. Start LocalStack ###
docker run -d --name localstack -p 4566:4566 -e SERVICES=s3,iam,sts,kms -e DEBUG=1 localstack/localstack
sleep 15
docker ps
curl -s http://localhost:4566/_localstack/health

### 2. AWS CLI setup ###
pip install awscli --quiet
aws configure set aws_access_key_id test
aws configure set aws_secret_access_key test
aws configure set region us-east-1
export EP="--endpoint-url=http://localhost:4566"
export BUCKET="medipay-tenant-clinic1"

### 3. Create tenant bucket ###
aws $EP s3 mb s3://$BUCKET

### 4. CEK-03 - Encryption at rest ###
KEY_ID=$(aws $EP kms create-key --query 'KeyMetadata.KeyId' --output text)
echo "KEY_ID=$KEY_ID"
aws $EP s3api put-bucket-encryption --bucket $BUCKET --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"'"$KEY_ID"'"}}]}'
aws $EP s3api get-bucket-encryption --bucket $BUCKET --query 'ServerSideEncryptionConfiguration.Rules[0]' --output json

### 5. DSP-04 - Data classification ###
echo "patient record placeholder - no real PHI" > record.txt
aws $EP s3 cp record.txt s3://$BUCKET/confidential/record.txt
aws $EP s3api put-object-tagging --bucket $BUCKET --key confidential/record.txt --tagging '{"TagSet":[{"Key":"classification","Value":"restricted-phi"}]}'
aws $EP s3api get-object-tagging --bucket $BUCKET --key confidential/record.txt

### 6. DSP-17 - Public exposure guardrail ###
aws $EP s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws $EP s3api get-public-access-block --bucket $BUCKET --query 'PublicAccessBlockConfiguration' --output json

### 7. DSP-16 - Retention and disposal ###
aws $EP s3api put-bucket-lifecycle-configuration --bucket $BUCKET --lifecycle-configuration '{"Rules":[{"ID":"expire-after-365-days","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":365}}]}'
aws $EP s3api get-bucket-lifecycle-configuration --bucket $BUCKET --query 'Rules[].[ID,Status]' --output json

### 8. IAM-05 - Least privilege role ###
aws $EP iam create-role --role-name patient-lookup-role --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

cat > policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::medipay-tenant-clinic1/confidential/*"}
  ]
}
EOF

aws $EP iam put-role-policy --role-name patient-lookup-role --policy-name s3-read-only --policy-document file://policy.json
aws $EP iam list-role-policies --role-name patient-lookup-role
aws $EP iam get-role-policy --role-name patient-lookup-role --policy-name s3-read-only

### 9. IVS-01 - Tenant isolation ###
aws $EP s3api put-bucket-policy --bucket $BUCKET --policy '{"Version":"2012-10-17","Statement":[{"Sid":"TenantIsolation","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::medipay-tenant-clinic1/*"],"Condition":{"StringNotEquals":{"aws:PrincipalTag/tenant":"clinic1"}}}]}'
aws $EP s3api get-bucket-policy --bucket $BUCKET --query 'Policy' --output text

### 10. LOG-07/LOG-02 - Management plane audit trail ###
docker logs assignment--localstack-1 2>&1 | grep -E "AWS [a-z0-9]+\.[A-Za-z]+ =>" > mgmt-trail.log
wc -l mgmt-trail.log
sha256sum mgmt-trail.log

### 11. AIS-06 - Pipeline security gate ###
cat > ci-gate.sh << 'EOF'
#!/usr/bin/env bash
if grep -rE "AKIA[0-9A-Z]{16}" . --include="*.py" --include="*.js" --include="*.sh" 2>/dev/null; then
  echo "BLOCKED: hardcoded credential pattern found"
  exit 1
fi
echo "No hardcoded credentials found"
exit 0
EOF
chmod +x ci-gate.sh
bash ci-gate.sh
echo "gate exit code: $?"

### 12. Save everything as one hashed evidence file (this becomes Appendix B) ###
{
  echo "MediPay technical evidence pack"
  echo "Collected: $(date -u) by <hafizul nizam>"
  echo "=== CEK-03 ===" ; aws $EP s3api get-bucket-encryption --bucket $BUCKET --query 'ServerSideEncryptionConfiguration.Rules[0]' --output json
  echo "=== DSP-04 ===" ; aws $EP s3api get-object-tagging --bucket $BUCKET --key confidential/record.txt
  echo "=== DSP-17 ===" ; aws $EP s3api get-public-access-block --bucket $BUCKET --query 'PublicAccessBlockConfiguration' --output json
  echo "=== DSP-16 ===" ; aws $EP s3api get-bucket-lifecycle-configuration --bucket $BUCKET --query 'Rules[].[ID,Status]' --output json
  echo "=== IAM-05 ===" ; aws $EP iam get-role-policy --role-name patient-lookup-role --policy-name s3-read-only
  echo "=== IVS-01 ===" ; aws $EP s3api get-bucket-policy --bucket $BUCKET --query 'Policy' --output text
  echo "=== LOG-07/LOG-02 ===" ; wc -l mgmt-trail.log
  echo "=== AIS-06 ===" ; bash ci-gate.sh
} | tee evidence-$(date +%Y%m%d).txt

sha256sum evidence-$(date +%Y%m%d).txt