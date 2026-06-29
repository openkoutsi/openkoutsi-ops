terraform {
  required_version = ">= 1.6"

  required_providers {
    upcloud = {
      source  = "UpCloudLtd/upcloud"
      version = "~> 5.0"
    }
  }

  # Remote, lockable state on UpCloud Managed Object Storage (S3-compatible).
  # State contains secrets (it is rendered into cloud-init), so it MUST be remote
  # and access-controlled. The bucket/endpoint/region/credentials are supplied at
  # init time so nothing sensitive is committed:
  #
  #   tofu init -backend-config=backend.hcl
  #
  # See backend.hcl.example for the expected keys.
  backend "s3" {
    # UpCloud Object Storage is not AWS, so disable the AWS-specific preflight.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}

provider "upcloud" {
  # Credentials come from UPCLOUD_USERNAME / UPCLOUD_PASSWORD in the environment.
}
