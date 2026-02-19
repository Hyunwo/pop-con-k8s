import boto3
import os

ec2 = boto3.client("ec2")

INSTANCE_ID = os.environ["INSTANCE_ID"]

def start(event, context):
    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    return {"status": "started"}

def stop(event, context):
    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    return {"status": "stopped"}
