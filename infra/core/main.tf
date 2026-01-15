terraform {
  required_version = ">= 1.5.0"

  required_providers {
    upcloud = {
      source  = "upcloudltd/upcloud"
      version = ">= 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
  }
}



