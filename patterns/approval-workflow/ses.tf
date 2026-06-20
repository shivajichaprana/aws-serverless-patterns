##############################################################################
# SES identities
#
# The sender identity must be verified before any email can be sent. While the
# account is in the SES sandbox, recipients must be verified too — toggle that
# with verify_approver_identities (set false once production access is granted).
#
# NOTE: aws_ses_email_identity only *creates* the identity; the owner of each
# inbox must still click the AWS verification email before sends succeed.
##############################################################################

resource "aws_ses_email_identity" "from" {
  email = var.from_address
}

resource "aws_ses_email_identity" "approvers" {
  for_each = var.verify_approver_identities ? toset(var.approver_addresses) : toset([])
  email    = each.value
}
