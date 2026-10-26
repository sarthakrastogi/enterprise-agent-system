# Identity provider for the platform. Cognito keeps the project self-contained;
# to use Entra ID / Okta instead, federate them into this pool (aws_cognito_identity_provider)
# or point the runtime/gateway authorizers at your IdP's discovery URL.

resource "aws_cognito_user_pool" "this" {
  name                     = "${var.project}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE" # set ACTIVE for production

  password_policy {
    minimum_length    = 14
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = true # no self sign-up
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "random_id" "domain" {
  byte_length = 4
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project}-${random_id.domain.hex}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# The chat UI signs users in with the authorization-code flow. Its access tokens
# are what the agent runtimes and the gateway accept (allowed_clients).
resource "aws_cognito_user_pool_client" "ui" {
  name                                 = "${var.project}-chat-ui"
  user_pool_id                         = aws_cognito_user_pool.this.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.ui_callback_urls
  logout_urls                          = var.ui_logout_urls
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  access_token_validity                = 60
  id_token_validity                    = 60
  refresh_token_validity               = 12
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
  prevent_user_existence_errors = "ENABLED"
}

# Groups are carried in the access token as `cognito:groups`. Agents use them in
# AgentSpec.allowed_groups; Cedar policy uses them for per-tool permissions.
resource "aws_cognito_user_group" "employees" {
  name         = "employees"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Everyone who may use the agent platform"
}

resource "aws_cognito_user_group" "platform_admins" {
  name         = "platform-admins"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "May use privileged tools such as closing tickets"
}
