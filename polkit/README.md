# MnMs.io Polkit Rules System

This directory contains Polkit rules implementing the MnMs.io three-dimensional permissions system:

## Dimensions

| Dimension | Description | Implementation |
|-----------|-------------|----------------|
| **Roles** | Hardcoded job functions | Polkit rules check group membership |
| **Attributes** | Environment variables, reflexive | Derived from username/service at runtime |
| **Scopes** | Permission levels | Action IDs in Polkit |

## User Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│ HOST (root / mnm-agent)                                     │
│   - Full machine access                                     │
│   - Runs: mnm-agent.service                                 │
├─────────────────────────────────────────────────────────────┤
│ APP/PACKAGE (e.g., xdoc_devops)                             │
│   - Member of: tenant group + role groups                   │
│   - Access to all services for that app                     │
├─────────────────────────────────────────────────────────────┤
│ SERVICE (e.g., xdoc_api, xdoc_geolocation)                  │
│   - Restricted to /srv/<tenant>/<service>/                  │
│   - Can only manage 'own' service (reflexive)               │
└─────────────────────────────────────────────────────────────┘
```

## Role Groups (OS Groups)

Create these groups on your system:

```bash
# Dev Roles
groupadd mnm-dbdevs      # Database developers
groupadd mnm-appdevs     # Application developers

# Ops Roles
groupadd mnm-sysops      # System operations
groupadd mnm-netops      # Network operations
groupadd mnm-dbaops      # Database administration
groupadd mnm-dataops     # Data operations
groupadd mnm-secops      # Security operations
groupadd mnm-chkops      # Audit/compliance

# Derived Roles
groupadd mnm-mlops       # ML operations
groupadd mnm-aiops       # AI operations
groupadd mnm-finops      # Financial operations
groupadd mnm-billops     # Billing operations
```

## Scope Actions (Polkit Action IDs)

| Scope | Action ID Pattern | Description |
|-------|-------------------|-------------|
| Monitoring | `io.mnm.scope.monitoring.*` | Read logs, streams |
| Configuration | `io.mnm.scope.configuration.*` | Modify configs |
| Provision | `io.mnm.scope.provision.*` | Control plane APIs |
| Change_Data | `io.mnm.scope.changedata.*` | Write/append data |

## Installation

```bash
# Copy Polkit rules (ordered by priority)
cp 00-mnm-base.rules /etc/polkit-1/rules.d/
cp 10-mnm-sysops.rules /etc/polkit-1/rules.d/
cp 20-mnm-netops.rules /etc/polkit-1/rules.d/
cp 30-mnm-dbops.rules /etc/polkit-1/rules.d/
cp 40-mnm-devops.rules /etc/polkit-1/rules.d/
cp 50-mnm-secops.rules /etc/polkit-1/rules.d/
cp 60-mnm-derived.rules /etc/polkit-1/rules.d/

# Copy action definitions
cp io.mnm.policy /usr/share/polkit-1/actions/

# Restart polkit
systemctl restart polkit
```

## Reflexive Attribute Examples

Polkit rules use reflexive checks - never hardcoding specific users:

```javascript
// User xdoc_api can restart xdoc-api.service
// User xdoc_geolocation can restart xdoc-geolocation.service
// Pattern: username with _ → service with -

function canManageOwnService(user, unit) {
    var expectedService = user.replace(/_/g, "-") + ".service";
    return unit === expectedService;
}
```

## Testing

```bash
# Test if user can perform action
pkcheck --action-id io.mnm.scope.monitoring.logs \
        --process $$ \
        --user xdoc_api

# List all MnM actions
pkaction | grep io.mnm
```
