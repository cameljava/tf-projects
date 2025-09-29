# test s3 IAM access policy

## Two Approaches

### Design 1: Per-User Bucket (your current approach)

Each user has their own bucket:

- corp-alice
- corp-bob
- corp-charlie

✅ Simpler — no need for prefix conditions.
✅ Strongest isolation — users cannot even see each other’s buckets.
⚠️ Requires creating one bucket per user (can be messy with 100s of users).

```IAM policy
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListOwnBucket",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::corp-${aws:username}"
        },
        {
            "Sid": "AccessOwnObjects",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject*"
            ],
            "Resource": "arn:aws:s3:::corp-${aws:username}/*"
        },
        {
            "Sid": "GetOwnBucketLocation",
            "Effect": "Allow",
            "Action": "s3:GetBucketLocation",
            "Resource": "arn:aws:s3:::corp-${aws:username}"
        }
    ]
}
```

### Design 2: Shared Bucket with Folders (prefix-based model)

One shared bucket

```code
  corp-shared
    - alice/
    - bob/
    - charlie/
```

✅ Easier to manage (one bucket for all users).
✅ s3:prefix ensures users only see their own folder in listings.
⚠️ Slightly more complex IAM.
⚠️ More risk if the policy is ever misconfigured (a user might see others’ data).

```IAM Policy

{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListOwnFolder",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::corp-shared",
            "Condition": {
                "StringLike": {
                    "s3:prefix": [
                        "",
                        "${aws:username}/*"
                    ]
                }
            }
        },
        {
            "Sid": "AccessOwnObjects",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject*"
            ],
            "Resource": "arn:aws:s3:::corp-shared/${aws:username}/*"
        },
        {
            "Sid": "GetSharedBucketLocation",
            "Effect": "Allow",
            "Action": "s3:GetBucketLocation",
            "Resource": "arn:aws:s3:::corp-shared"
        }
    ]
}
```

🔎 When to Choose Which

- Per-user bucket → better for strict isolation (finance, healthcare, compliance).
- Shared bucket with folders → better for ease of management (lots of users, team collaboration).

### How to test

1. Save each strategy in its own folder (e.g., strategy1-per-user/ and strategy2-shared/).

2. Run:

```bash
terraform init
terraform apply
```

3. Create access keys for Alice and Bob

```bash
aws iam create-access-key --user-name alice
aws iam create-access-key --user-name bob
```

4. Configure AWS CLI profiles (alice, bob).
5. Try commands:

```bash
aws s3 ls --profile alice
aws s3 ls s3://corp-shared/ --profile alice
aws s3 cp file.txt s3://corp-shared/alice/ --profile alice
aws s3 cp file.txt s3://corp-shared/bob/ --profile alice # should fail
```


### clean up

```bash
aws iam delete-access-key --user-name alice --access-key-id AKIAXLWLAKDZZS2YUEGO

aws s3 rm s3://corp-shared-4e7b33af --recursive
aws s3 ls s3://corp-shared-4e7b33af --recursive
```
