# Infinibay v0.3.0 Upgrade

## What's New

### Firewall Rule Presets
- Pre-configured firewall rule templates for common scenarios
- Quick setup for web servers, database servers, and custom applications
- Import/export functionality for sharing rule sets

### VM Scheduling
- Schedule VM start/stop times for automated power management
- Recurring schedules (daily, weekly, monthly)
- Timezone-aware scheduling

### Department Management
- Organize VMs by department for better resource tracking
- Department-level quotas and permissions
- All existing VMs automatically assigned to "Default" department

## Breaking Changes

### GraphQL API Changes
- **DEPRECATED**: `createFilter` mutation has been deprecated in favor of `createFirewallRule`
- **Migration Path**: Update your API clients to use the new `createFirewallRule` mutation
- **Timeline**: `createFilter` will be removed in v0.4.0

### Database Schema Changes
- **VMs now require `departmentId`**: All VMs must be associated with a department
- **Automatic Migration**: Existing VMs are automatically assigned to the "Default" department during upgrade
- **Action Required**: Review VM department assignments after upgrade and reassign as needed

## Upgrade Process

This upgrade includes:
1. Database schema migrations (adds `departments` table, `departmentId` column to VMs)
2. Data migrations (creates default department, assigns existing VMs)
3. Backend code updates (new GraphQL resolvers, scheduling engine)
4. Frontend updates (new UI for departments and scheduling)

**Estimated Time**: 5-10 minutes
**Downtime**: ~2 minutes during service restarts

## Post-Upgrade Steps

1. **Review Department Assignments**
   - Navigate to Settings > Departments
   - Create departments for your organization
   - Reassign VMs from "Default" to appropriate departments

2. **Update API Clients** (if applicable)
   - Replace `createFilter` with `createFirewallRule` in your code
   - Test API integrations

3. **Explore New Features**
   - Try creating firewall rule presets
   - Set up VM schedules for non-production environments

## Rollback

If you encounter issues, you can rollback to v0.2.0:
```bash
./run.sh rollback
```

This will restore your database and code to the pre-upgrade state.

## Support

For issues or questions:
- Check the troubleshooting guide: `lxd/UPDATE_GUIDE.md`
- Review logs: `./run.sh logs backend` or `./run.sh logs frontend`
- Report bugs: [GitHub Issues](https://github.com/infinibay/infinibay/issues)
