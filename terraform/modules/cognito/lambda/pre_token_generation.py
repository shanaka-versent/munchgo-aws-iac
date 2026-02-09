# MunchGo Cognito Pre Token Generation Lambda v2
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Enriches Cognito ID and access tokens with custom claims:
#   - custom:roles — comma-separated list of user's Cognito group memberships
#
# Triggered by Cognito before token generation (V2_0 trigger).
# Groups in Cognito map 1:1 to MunchGo roles:
#   ROLE_CUSTOMER, ROLE_RESTAURANT_OWNER, ROLE_COURIER, ROLE_ADMIN
#
# Kong's openid-connect plugin reads these claims and forwards them as
# upstream headers (X-User-Roles) to backend services.

import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Cognito Pre Token Generation V2_0 trigger.

    Adds custom claims to both ID token and access token:
      - custom:roles — user's group memberships as comma-separated string

    Event structure (V2_0):
    {
        "request": {
            "groupConfiguration": {
                "groupsToOverride": ["ROLE_CUSTOMER", ...],
                ...
            },
            "userAttributes": {
                "sub": "...",
                "email": "...",
                ...
            },
            "scopes": ["openid", "email", "profile"]
        },
        "response": {
            "claimsAndScopeOverrideDetails": {
                "idTokenGeneration": { "claimsToAddOrOverride": {} },
                "accessTokenGeneration": { "claimsToAddOrOverride": {}, "scopesToAdd": [], "scopesToSuppress": [] }
            }
        }
    }
    """
    logger.info("Pre Token Generation V2_0 triggered for user: %s",
                event.get("userName", "unknown"))

    # Extract user's Cognito groups (these are MunchGo roles)
    groups = event.get("request", {}).get("groupConfiguration", {}).get("groupsToOverride", [])
    roles_claim = ",".join(groups) if groups else ""

    logger.info("User groups (roles): %s", roles_claim)

    # Build claims override for both ID and access tokens
    claims_override = {}
    if roles_claim:
        claims_override["custom:roles"] = roles_claim

    # Set claims on both tokens
    event["response"]["claimsAndScopeOverrideDetails"] = {
        "idTokenGeneration": {
            "claimsToAddOrOverride": claims_override
        },
        "accessTokenGeneration": {
            "claimsToAddOrOverride": claims_override,
            "scopesToAdd": [],
            "scopesToSuppress": []
        }
    }

    logger.info("Token claims enriched successfully")
    return event
