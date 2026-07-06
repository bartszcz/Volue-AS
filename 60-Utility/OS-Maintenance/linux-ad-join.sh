#!/usr/bin/env bash
set -euo pipefail

DOMAIN_REALM="VOLUEAD.VOLUE.COM"
DOMAIN_FQDN="voluead.volue.com"

FQDN="$1"
JOIN_USER="$2"

PERMIT_GROUPS=(
  "ITO-SERVER-ADMINS@VOLUEAD.VOLUE.COM"
  
)

SHORTNAME="${FQDN%%.*}"

hostnamectl set-hostname "$FQDN"

awk -v fqdn="$FQDN" -v short="$SHORTNAME" '
BEGIN{done=0}
/^127\.0\.1\.1/{
  print "127.0.1.1 " fqdn " " short
  done=1
  next
}
{print}
END{
  if(done==0){
    print "127.0.1.1 " fqdn " " short
  }
}
' /etc/hosts > /tmp/hosts.new

cp /etc/hosts /etc/hosts.bak
mv /tmp/hosts.new /etc/hosts

apt update -y
apt install -y sssd sssd-ad sssd-tools libpam-sss libnss-sss realmd adcli samba-common-bin packagekit

mkdir -p /etc/sssd
chmod 700 /etc/sssd
chown root:root /etc/sssd

realm discover "$DOMAIN_FQDN"

realm join -v -U "$JOIN_USER" "$DOMAIN_REALM"

pam-auth-update --enable mkhomedir

realm deny --all

for g in "${PERMIT_GROUPS[@]}"; do
  realm permit -g "$g"
done

realm permit "${JOIN_USER}@${DOMAIN_FQDN}"

cat > /etc/sudoers.d/99-voluead-admins <<EOF
%ITO-SERVER-ADMINS@VOLUEAD.VOLUE.COM ALL=(ALL) NOPASSWD:ALL
EOF

chmod 440 /etc/sudoers.d/99-voluead-admins

visudo -cf /etc/sudoers
visudo -cf /etc/sudoers.d/99-voluead-admins

systemctl restart sssd
