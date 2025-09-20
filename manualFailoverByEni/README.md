## Failover by ENI

main.tf set up two ec2 instances, primary instance attached to ENI, test manually detach and reattach to standby instance.

Theoritically, can also detach an Elastic IP from the primary instance and associate it with the standby:

```bash
aws ec2 disassociate-address --association-id eipassoc-xxxx
aws ec2 associate-address --instance-id i-standby --allocation-id eip-xxxx
```
This works, but:
- You only move the public IP.
- The private IP of the app instance changes.
- You lose the benefits of ENI-based HA, especially for apps with private networking dependencies.

Recommended: 

- Move the ENI (with private + Elastic IP) between instances.
- Don’t move the Elastic IP separately — it’s already bound to the ENI.
- This allows transparent failover, both for private network traffic and public traffic (Elastic IP).

### pratice 1, manually update in runtime, fix terraform

manually detach eni from primary instance, then attach to failover instance.
To sync with terraform:

- manually update main.tf file to target state
- use terraform import and terraform state rm to update state file align with runtime and terraform file

### practice 2, use terraform to excute failover

