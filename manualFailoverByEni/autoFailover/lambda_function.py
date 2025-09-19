import os
import boto3

EC2 = boto3.client('ec2')

ENI_ID = os.environ['ENI_ID']
STANDBY = os.environ['STANDBY_ID']
DEVICE_INDEX = int(os.environ['DEVICE_INDEX'])

def lambda_handler(event, context):
    eni = EC2.describe_network_interfaces(NetworkInterfaceIds=[ENI_ID])['NetworkInterfaces'][0]
    attachment_id = eni.get('Attachment', {}).get('AttachmentId')

    if attachment_id:
        EC2.detach_network_interface(AttachmentId=attachment_id, Force=True)
        waiter = EC2.get_waiter('network_interface_available')
        waiter.wait(NetworkInterfaceIds=[ENI_ID])

    EC2.attach_network_interface(
        NetworkInterfaceId=ENI_ID,
        InstanceId=STANDBY,
        DeviceIndex=DEVICE_INDEX
    )

    print(f"ENI {ENI_ID} moved to standby {STANDBY}")