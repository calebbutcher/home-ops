terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# ---------------------------------------------------------------------------
# CyberArk CCP — pull Proxmox API token from PAM
# Safe: HLB-Hypervisor-Root  |  Object: proxmox-api-token
#   UserName field → token ID   (e.g. terraform@pve!home-ops)
#   Content field  → token secret
#
# Replace PLACEHOLDER-APP-ID with your CCP App ID after creating it in PAM.
# ---------------------------------------------------------------------------
data "http" "ccp_proxmox" {
  url = "https://${var.ccp_host}/AIMWebService/api/Accounts?AppID=PLACEHOLDER-APP-ID&Safe=${var.ccp_safe}&Object=${var.ccp_object}"

  request_headers = {
    Accept = "application/json"
  }

  # Prevent Terraform from logging the response (contains secret)
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "CCP credential fetch failed (HTTP ${self.status_code}). Check App ID, Safe, and Object name."
    }
  }
}

locals {
  _ccp             = jsondecode(data.http.ccp_proxmox.response_body)
  proxmox_token_id = local._ccp.UserName    # e.g. "terraform@pve!home-ops"
  proxmox_token_secret = local._ccp.Content # the raw secret
}

provider "proxmox" {
  endpoint  = "https://${var.proxmox_host}:8006/"
  api_token = "${local.proxmox_token_id}=${local.proxmox_token_secret}"
  insecure  = var.proxmox_tls_insecure
}
