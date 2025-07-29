terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "vault" {
  address = "http://127.0.0.1:8200"
  # You can use token authentication or another method as needed
  # token = var.vault_token
  # Or use environment variable VAULT_TOKEN
}