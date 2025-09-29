# s3:prefix

📂 What is a “prefix” in S3?
- In Amazon S3, there are no real folders, just object keys
- A prefix is simply the beginning of an object’s key (its “path”)

Example:

```code
bucket: corp-alice
objects:
  alice/file1.txt
  alice/photos/photo1.png
  bob/file2.txt
```

Here:
• The prefix alice/ matches all objects that start with alice/.
• The prefix bob/ matches all objects that start with bob/.


📜 How s3:prefix Works

When you use s3:ListBucket, the s3:prefix condition tells AWS what parts of the bucket a user is allowed to list.

Example from your policy:

```code
"Condition": {
  "StringLike": {
    "s3:prefix": [
      "",
      "${aws:username}*"
    ]
  }
}
```

This means: 1. "" → allow listing the root level of the bucket (so the CLI/console works when showing top-level folders). 2. "${aws:username}\*" → allow listing only keys that start with the IAM username.


🔎 Practical Effect

Suppose Alice is the IAM username (aws:username = alice).

if She runs:

```code
aws s3 ls s3://corp-alice/
```

- She will only see objects where the key begins with alice (e.g., alice/file1.txt).
- She cannot list objects like bob/file2.txt.

But here’s the subtle part:
👉 Even though she can’t list Bob’s files, if she somehow knew the full key (bob/file2.txt), the object-level permissions (your GetObject statement) already restrict access to only corp-alice/\*, so she wouldn’t be able to read it either.


⚠️ Common Misunderstanding
- s3:prefix only applies to listing (ListBucket).
- It does not prevent direct access. That’s why you also need the second statement (PutObject, GetObject, DeleteObject) scoped to corp-${aws:username}/\*.

✅ Summary:
- s3:prefix = filter for what parts of the bucket you can list.
- It ensures users only see “their folder” in the S3 console/CLI.
- Actual access is still controlled by the Resource in object-level permissions.
