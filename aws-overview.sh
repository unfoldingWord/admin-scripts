#!/usr/bin/env bash
#
# aws-overview.sh
# A simple overview of AWS resources across all enabled regions.
# Uses the AWS CLI. Assumes credentials come from an IAM instance role.
#
# Usage:
#   ./aws-overview.sh                    # print everything to screen
#   ./aws-overview.sh > report.txt       # save the whole run to one file
#   ./aws-overview.sh -o out             # split output, region-first (see below)
#   ./aws-overview.sh -o out -r us-west-2 # one region (global section still runs)
#   ./aws-overview.sh -r "us-east-1 eu-west-1"  # limit to specific regions
#
# Split layout (-o/--outdir set), one directory per region:
#   out/us-east-1/overview.txt        # always written: what was checked + status
#   out/us-east-1/ec2.txt             # summary table (index) for a type...
#   out/us-east-1/ec2/                # ...and one JSON file per resource:
#   out/us-east-1/ec2/i-0abc123.json  #    full detail for that resource
#   out/global/overview.txt           # S3 + IAM (region-independent)
# A type that came back empty gets no file; overview.txt records it as "none".
# The "tagged" list is ARNs (not filename-safe), so it stays index-only.
#
# Requires: aws cli v2, jq, column (util-linux)

set -euo pipefail

# --- config ---------------------------------------------------------------

# Leave empty to auto-detect all enabled regions.
# Or set your own list, e.g. REGIONS="us-east-1 eu-west-1"
REGIONS="${REGIONS:-}"

# Output directory for split mode. Set with -o/--outdir (see arg parsing
# below). Empty means print everything to stdout.
OUTDIR=""

usage() {
  cat <<EOF
Usage: aws-overview.sh [-o DIR] [-r "REGIONS"]

  -o, --outdir DIR    Split output into region-first files under DIR
                      (see the layout in this script's header comment).
                      Omit to print everything to stdout.
  -r, --regions LIST  Space-separated regions to scan, e.g. "us-east-1 eu-west-1".
                      Default: all enabled regions. Overrides \$REGIONS.
                      The global section (S3, IAM, Route 53, CloudFront) always
                      runs regardless of this flag.
  -h, --help          Show this help and exit.

Examples:
  aws-overview.sh -o out -r us-west-2          # one region + global, split out
  aws-overview.sh -r "us-east-1 eu-west-1"     # two regions, to stdout

Environment:
  REGIONS   Same as --regions (the flag wins if both are given).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--outdir)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      OUTDIR="$2"; shift 2 ;;
    --outdir=*)
      OUTDIR="${1#*=}"; shift ;;
    -r|--regions)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      REGIONS="$2"; shift 2 ;;
    --regions=*)
      REGIONS="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- helpers --------------------------------------------------------------

hr() { printf '%s\n' "--------------------------------------------------------"; }

# Progress/context always goes to stderr so it never pollutes split files.
note() { echo "$*" >&2; }

# Per-region state (split mode).
REGION_DIR=""      # current region's output directory
REGION_FILES=""    # comma-separated list of index files written this region

# Begin a region (or the pseudo-region "global").
region_begin() {
  local region="$1"
  if [ -n "$OUTDIR" ]; then
    REGION_DIR="$OUTDIR/$region"
    REGION_FILES=""
    rm -rf "$REGION_DIR"              # fresh start; clears stale detail dirs too
    mkdir -p "$REGION_DIR"
    {
      echo "Region: $region"
      echo "Checked: $(date +%F)"
      echo
    } > "$REGION_DIR/overview.txt"
  else
    note ""
    note "== REGION: $region =="
  fi
}

# Finish a region: write the overview footer.
region_end() {
  [ -n "$OUTDIR" ] || return 0
  {
    echo
    if [ -z "$REGION_FILES" ]; then
      echo "No resources found in this region."
    else
      echo "Files written: $REGION_FILES"
    fi
  } >> "$REGION_DIR/overview.txt"
}

# Record a resource type's status in the overview and remember its index file.
mark() {
  local key="$1" status="$2"
  printf '  %-18s %s\n' "$key" "$status" >> "$REGION_DIR/overview.txt"
}
remember() {
  REGION_FILES="${REGION_FILES:+$REGION_FILES, }$1"
}

# Run an AWS sub-call and print its JSON on success, or nothing on failure.
# Used by the S3/IAM enrichers: many detail calls legitimately error when a
# feature is unconfigured (no encryption, no policy, no tags), and one missing
# feature must not abort the whole resource. Callers default the empty result
# to JSON null via "${var:-null}".
try_json() { "$@" 2>/dev/null || true; }

# The tagged-ARN list, one ARN per line (JSON in, jq out). A plain
# `--output text` list projection joins the ARNs with tabs, so we parse the
# JSON instead. Fails (non-zero) if the API call fails, so emit_raw can tell
# "no permission" from an empty list.
tagged_arns() {
  aws resourcegroupstaggingapi get-resources --region "$1" --output json \
    | jq -r '.ResourceTagMappingList[].ResourceARN'
}

# Emit a plain list (no per-resource detail). Used for the tagged-ARN list.
#   emit_raw <key> <label> <command...>
emit_raw() {
  local key="$1" label="$2"; shift 2
  local out status
  if out="$("$@" 2>/dev/null)"; then
    if [ -z "$out" ] || [ "$out" = "None" ]; then status="none"; else status="ok"; fi
  else
    status="no permission"
  fi

  if [ -n "$OUTDIR" ]; then
    mark "$key" "$status"
    case "$status" in
      ok)
        { echo "-- $label --"; printf '%s\n' "$out" | sed 's/^/  /'; } > "$REGION_DIR/$key.txt"
        remember "$key.txt" ;;
      "no permission")
        { echo "-- $label --"; echo "  ($label: error or no permission)"; } > "$REGION_DIR/$key.txt"
        remember "$key.txt" ;;
    esac
  else
    echo; echo "-- $label --"
    case "$status" in
      ok)   printf '%s\n' "$out" | sed 's/^/  /' ;;
      none) echo "  ($label: none)" ;;
      *)    echo "  ($label: error or no permission)" ;;
    esac
  fi
}

# Render an already-fetched resource array into a summary table (the index)
# plus one detail JSON file per resource. Shared by emit and emit_deep so both
# produce identical output; only the way the JSON is obtained differs.
#   render <key> <label> <list_jq> <id_jq> <header> <row_jq> <status> <json>
#     status   ok | none | "no permission" (already decided by the caller)
#     json     the full JSON blob whose <list_jq> points at the array
render() {
  local key="$1" label="$2" list_jq="$3" id_jq="$4" header="$5" row_jq="$6" status="$7" out="$8"
  local table id elem

  if [ "$status" = "ok" ]; then
    table="$(
      {
        printf '%b\n' "$header"
        printf '%s' "$out" | jq -r "($list_jq)[] | [$row_jq] | @tsv"
      } | column -t -s "$(printf '\t')"
    )"
  fi

  if [ -n "$OUTDIR" ]; then
    mark "$key" "$status"
    case "$status" in
      ok)
        { echo "-- $label --"; printf '%s\n' "$table" | sed 's/^/  /'; } > "$REGION_DIR/$key.txt"
        remember "$key.txt"
        mkdir -p "$REGION_DIR/$key"
        printf '%s' "$out" | jq -c "($list_jq)[]" | while IFS= read -r elem; do
          id="$(printf '%s' "$elem" | jq -r "$id_jq")"
          # Sanitize for use as a filename only. Ids like log-group paths,
          # alarm names, or hosted-zone ids may contain / : or spaces; the
          # true id always stays intact inside the JSON.
          id="$(printf '%s' "$id" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
          printf '%s' "$elem" | jq . > "$REGION_DIR/$key/$id.json"
        done
        ;;
      "no permission")
        { echo "-- $label --"; echo "  ($label: error or no permission)"; } > "$REGION_DIR/$key.txt"
        remember "$key.txt" ;;
    esac
  else
    echo; echo "-- $label --"
    case "$status" in
      ok)   printf '%s\n' "$table" | sed 's/^/  /' ;;
      none) echo "  ($label: none)" ;;
      *)    echo "  ($label: error or no permission)" ;;
    esac
  fi
}

# Emit a typed resource: one full describe/list call (JSON) becomes both a
# summary table (the index) and one detail JSON file per resource.
#   emit <key> <label> <list_jq> <id_jq> <header> <row_jq> <aws command... --output json>
#     list_jq   jq path to the array of resources, e.g. '.Vpcs'
#     id_jq     jq expr for one resource's id,     e.g. '.VpcId'
#     header    tab-separated column titles,       e.g. 'ID\tCIDR\tDefault'
#     row_jq    jq exprs for one summary row,      e.g. '.VpcId, .CidrBlock, .IsDefault'
emit() {
  local key="$1" label="$2" list_jq="$3" id_jq="$4" header="$5" row_jq="$6"; shift 6
  local out status n

  if out="$("$@" 2>/dev/null)"; then
    n="$(printf '%s' "$out" | jq "($list_jq) | length" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -eq 0 ]; then status="none"; else status="ok"; fi
  else
    status="no permission"; out=""
  fi

  render "$key" "$label" "$list_jq" "$id_jq" "$header" "$row_jq" "$status" "$out"
}

# Emit a typed resource that needs list-then-describe: the list call only
# yields ids, so we describe each id and assemble the full objects into one
# array before rendering. Use for services whose list-* is near-useless
# (KMS, DynamoDB, ACM).
#   emit_deep <key> <label> <ids_jq> <unwrap_jq> <filter_jq> <id_jq> \
#             <header> <row_jq> <list cmd...> -- <describe cmd... with {} for id>
#     ids_jq    jq -r expr yielding one id per line from the list output,
#               e.g. '.TableNames[]' or '.Keys[].KeyId'
#     unwrap_jq jq path to the resource object in a describe output,
#               e.g. '.Table', '.KeyMetadata'
#     filter_jq keep-if boolean on the unwrapped object ('true' for all),
#               e.g. '.KeyManager == "CUSTOMER"'
#     {}        placeholder in the describe command, replaced by each id
emit_deep() {
  local key="$1" label="$2" ids_jq="$3" unwrap_jq="$4" filter_jq="$5" id_jq="$6" \
        header="$7" row_jq="$8"; shift 8

  # Split remaining args at the first '--': list command | describe template.
  local list_cmd=() desc_tmpl=() seen=0 a
  for a in "$@"; do
    if [ "$seen" -eq 0 ] && [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" -eq 0 ]; then list_cmd+=("$a"); else desc_tmpl+=("$a"); fi
  done

  local status out ids id desc obj items="[]" cmd t
  if out="$("${list_cmd[@]}" 2>/dev/null)"; then
    ids="$(printf '%s' "$out" | jq -r "$ids_jq" 2>/dev/null || true)"
    if [ -z "$ids" ]; then
      status="none"
    else
      status="ok"
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        cmd=()
        for t in "${desc_tmpl[@]}"; do
          if [ "$t" = "{}" ]; then cmd+=("$id"); else cmd+=("$t"); fi
        done
        if desc="$("${cmd[@]}" 2>/dev/null)"; then
          obj="$(printf '%s' "$desc" | jq -c "$unwrap_jq | select($filter_jq)" 2>/dev/null || true)"
          if [ -n "$obj" ] && [ "$obj" != "null" ]; then
            items="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$items")"
          fi
        fi
      done <<<"$ids"
      [ "$(jq 'length' <<<"$items")" -eq 0 ] && status="none"
    fi
  else
    status="no permission"
  fi

  render "$key" "$label" '.items' "$id_jq" "$header" "$row_jq" "$status" "{\"items\":$items}"
}

# S3 buckets with per-bucket security detail. list-buckets only yields name +
# date, so we enrich each bucket with location, versioning, encryption, public
# access block, policy, and tags (each via try_json, so an unconfigured feature
# just becomes null). Summary table carries at-a-glance security flags; the
# full detail lands in s3/<name>.json.
emit_s3_detail() {
  local key="s3" label="S3 buckets"
  local header='Name\tRegion\tVersioning\tEncrypted\tPublicBlocked\tHasPolicy'
  local row='.Name, .Region, .VersioningStatus, .Encrypted, .PublicBlocked, .HasPolicy'
  local out name created loc region ver enc pab pol tags obj items="[]"

  if ! out="$(aws s3api list-buckets --output json 2>/dev/null)"; then
    render "$key" "$label" '.items' '.Name' "$header" "$row" "no permission" ""
    return
  fi

  while IFS=$'\t' read -r name created; do
    [ -n "$name" ] || continue
    loc="$(try_json aws s3api get-bucket-location --bucket "$name" --output json)"
    region="$(printf '%s' "${loc:-}" | jq -r '.LocationConstraint // "us-east-1"' 2>/dev/null || true)"
    [ -n "$region" ] && [ "$region" != "null" ] || region="us-east-1"

    ver="$(try_json aws s3api get-bucket-versioning  --bucket "$name" --region "$region" --output json)"
    enc="$(try_json aws s3api get-bucket-encryption  --bucket "$name" --region "$region" --output json)"
    pab="$(try_json aws s3api get-public-access-block --bucket "$name" --region "$region" --output json)"
    pol="$(try_json aws s3api get-bucket-policy      --bucket "$name" --region "$region" --output json)"
    tags="$(try_json aws s3api get-bucket-tagging    --bucket "$name" --region "$region" --output json)"

    obj="$(jq -n \
      --arg  name    "$name" \
      --arg  created "$created" \
      --arg  region  "$region" \
      --argjson ver  "${ver:-null}" \
      --argjson enc  "${enc:-null}" \
      --argjson pab  "${pab:-null}" \
      --argjson pol  "${pol:-null}" \
      --argjson tags "${tags:-null}" \
      '{
         Name: $name, CreationDate: $created, Region: $region,
         Versioning: $ver,
         VersioningStatus: ($ver.Status // "Off"),
         Encryption: ($enc.ServerSideEncryptionConfiguration // null),
         Encrypted: (if ($enc.ServerSideEncryptionConfiguration // null) then "yes" else "no" end),
         PublicAccessBlock: ($pab.PublicAccessBlockConfiguration // null),
         PublicBlocked: (
           ($pab.PublicAccessBlockConfiguration // null) as $c
           | if   $c == null then "no"
             elif ($c.BlockPublicAcls and $c.IgnorePublicAcls and $c.BlockPublicPolicy and $c.RestrictPublicBuckets) then "yes"
             elif ($c.BlockPublicAcls or  $c.IgnorePublicAcls or  $c.BlockPublicPolicy or  $c.RestrictPublicBuckets) then "partial"
             else "no" end
         ),
         Policy: (if $pol == null then null else ($pol.Policy | fromjson) end),
         HasPolicy: (if $pol == null then "no" else "yes" end),
         Tags: ($tags.TagSet // [])
       }' 2>/dev/null || true)"
    [ -n "$obj" ] && items="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$items")"
  done < <(printf '%s' "$out" | jq -r '.Buckets[] | [.Name, .CreationDate] | @tsv')

  local status; [ "$(jq 'length' <<<"$items")" -eq 0 ] && status="none" || status="ok"
  render "$key" "$label" '.items' '.Name' "$header" "$row" "$status" "{\"items\":$items}"
}

# IAM roles with per-role policy detail. list-roles yields the role + trust
# policy; we add attached managed policies, inline policy documents, and
# instance profiles (each via try_json). Summary shows policy counts.
emit_iam_detail() {
  local key="iam" label="IAM roles"
  local header='Name\tCreated\tManaged\tInline'
  local row='.RoleName, .CreateDate, .ManagedCount, .InlineCount'
  local out role name att inl ipf pn pdoc inline_docs obj items="[]"

  if ! out="$(aws iam list-roles --output json 2>/dev/null)"; then
    render "$key" "$label" '.items' '.RoleName' "$header" "$row" "no permission" ""
    return
  fi

  while IFS= read -r role; do
    [ -n "$role" ] || continue
    name="$(printf '%s' "$role" | jq -r '.RoleName')"
    att="$(try_json aws iam list-attached-role-policies    --role-name "$name" --output json)"
    inl="$(try_json aws iam list-role-policies             --role-name "$name" --output json)"
    ipf="$(try_json aws iam list-instance-profiles-for-role --role-name "$name" --output json)"

    inline_docs="{}"
    while IFS= read -r pn; do
      [ -n "$pn" ] || continue
      pdoc="$(try_json aws iam get-role-policy --role-name "$name" --policy-name "$pn" --output json)"
      [ -n "$pdoc" ] || continue
      inline_docs="$(jq -c --arg n "$pn" --argjson d "$(printf '%s' "$pdoc" | jq '.PolicyDocument')" \
        '. + {($n): $d}' <<<"$inline_docs")"
    done < <(printf '%s' "${inl:-}" | jq -r '.PolicyNames[]?' 2>/dev/null || true)

    obj="$(printf '%s' "$role" | jq -c \
      --argjson att "${att:-null}" \
      --argjson ipf "${ipf:-null}" \
      --argjson inldocs "$inline_docs" \
      '. + {
         AttachedManagedPolicies: ($att.AttachedPolicies // []),
         InlinePolicies: $inldocs,
         InstanceProfiles: [ ($ipf.InstanceProfiles // [])[].InstanceProfileName ],
         ManagedCount: (($att.AttachedPolicies // []) | length),
         InlineCount: ($inldocs | length)
       }' 2>/dev/null || true)"
    [ -n "$obj" ] && items="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$items")"
  done < <(printf '%s' "$out" | jq -c '.Roles[]')

  local status; [ "$(jq 'length' <<<"$items")" -eq 0 ] && status="none" || status="ok"
  render "$key" "$label" '.items' '.RoleName' "$header" "$row" "$status" "{\"items\":$items}"
}

# Account-level S3 Public Access Block (one setting per account, via
# s3control). When ON it overrides every bucket's own PAB, so it's the
# authority on whether the per-bucket "PublicBlocked=no" flags actually matter.
# get-public-access-block returns NoSuchPublicAccessBlockConfiguration (an
# error) when none is set, which we distinguish from a real permission error by
# inspecting stderr.
emit_account_pab() {
  local key="account-pab" label="Account S3 Public Access Block"
  local header='Account\tBlockPublicAcls\tIgnorePublicAcls\tBlockPublicPolicy\tRestrictPublicBuckets\tAllBlocked'
  local row='.Account, .BlockPublicAcls, .IgnorePublicAcls, .BlockPublicPolicy, .RestrictPublicBuckets, .AllBlocked'
  local raw rc cfg obj status pab_region

  # s3control is a REGIONAL service (unlike s3api/iam/route53), so the call
  # needs an explicit region even though the account-level PAB it returns is
  # account-global. Use the first scanned region (partition-safe) rather than
  # hardcoding us-east-1, which does not exist in GovCloud/China.
  pab_region="${REGIONS%% *}"; [ -n "$pab_region" ] || pab_region="us-east-1"

  raw="$(aws s3control get-public-access-block --account-id "$ACCOUNT_ID" --region "$pab_region" --output json 2>&1)" && rc=0 || rc=$?

  if [ "${rc:-1}" -ne 0 ]; then
    # Not configured is the normal "no block" case; anything else is an error.
    if printf '%s' "$raw" | grep -q 'NoSuchPublicAccessBlockConfiguration'; then
      cfg=null
    else
      render "$key" "$label" '.items' '.Account' "$header" "$row" "no permission" ""
      return
    fi
  else
    cfg="$(printf '%s' "$raw" | jq -c '.PublicAccessBlockConfiguration // null')"
  fi

  obj="$(jq -n --arg acct "$ACCOUNT_ID" --argjson cfg "${cfg:-null}" '
    {
      Account: $acct,
      BlockPublicAcls:       ($cfg.BlockPublicAcls // false),
      IgnorePublicAcls:      ($cfg.IgnorePublicAcls // false),
      BlockPublicPolicy:     ($cfg.BlockPublicPolicy // false),
      RestrictPublicBuckets: ($cfg.RestrictPublicBuckets // false),
      AllBlocked: (
        if   $cfg == null then "no (not configured)"
        elif ($cfg.BlockPublicAcls and $cfg.IgnorePublicAcls and $cfg.BlockPublicPolicy and $cfg.RestrictPublicBuckets) then "yes"
        else "partial" end
      ),
      PublicAccessBlockConfiguration: $cfg
    }')"
  status="ok"
  render "$key" "$label" '.items' '.Account' "$header" "$row" "$status" "{\"items\":[$obj]}"
}

# --- account context ------------------------------------------------------

if [ -n "$OUTDIR" ]; then
  mkdir -p "$OUTDIR"
  note "Splitting output (region-first) into: $OUTDIR/<region>/"
fi

note ""
note "== Account =="
aws sts get-caller-identity \
  --query '{Account:Account, Arn:Arn}' --output table >&2
# Account id, used for account-level calls (e.g. s3control PAB).
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"

# --- region list ----------------------------------------------------------

if [ -z "$REGIONS" ]; then
  REGIONS="$(aws ec2 describe-regions \
    --query 'Regions[].RegionName' --output text)"
fi

note ""
note "Regions to scan: $REGIONS"

# --- global (region-independent) services ---------------------------------

note ""
note "Scanning global services..."
region_begin global

emit_s3_detail

emit_account_pab

emit_iam_detail

emit route53 "Route 53 hosted zones" '.HostedZones' '(.Id | ltrimstr("/hostedzone/"))' \
  'ID\tName\tRecords\tPrivate' \
  '(.Id | ltrimstr("/hostedzone/")), .Name, .ResourceRecordSetCount, .Config.PrivateZone' \
  aws route53 list-hosted-zones --output json

emit cloudfront "CloudFront distributions" '(.DistributionList.Items // [])' '.Id' \
  'ID\tDomain\tStatus\tEnabled\tAliases' \
  '.Id, .DomainName, .Status, .Enabled, ((.Aliases.Items // []) | join(","))' \
  aws cloudfront list-distributions --output json

emit iam-policies "IAM customer-managed policies" '.Policies' '.PolicyName' \
  'Name\tAttached\tCreated\tARN' \
  '.PolicyName, .AttachmentCount, .CreateDate, .Arn' \
  aws iam list-policies --scope Local --output json

region_end

# --- per-region loop ------------------------------------------------------

for region in $REGIONS; do
  note "Scanning region: $region"
  region_begin "$region"

  emit_raw tagged "All taggable resources (Tagging API)" \
    tagged_arns "$region"

  emit ec2 "EC2 instances" '[.Reservations[].Instances[]]' '.InstanceId' \
    'ID\tType\tState\tIP' \
    '.InstanceId, .InstanceType, .State.Name, (.PrivateIpAddress // "-")' \
    aws ec2 describe-instances --region "$region" --output json

  emit vpc "VPCs" '.Vpcs' '.VpcId' \
    'ID\tCIDR\tDefault' \
    '.VpcId, .CidrBlock, .IsDefault' \
    aws ec2 describe-vpcs --region "$region" --output json

  emit subnets "Subnets" '.Subnets' '.SubnetId' \
    'ID\tVPC\tCIDR\tAZ' \
    '.SubnetId, .VpcId, .CidrBlock, .AvailabilityZone' \
    aws ec2 describe-subnets --region "$region" --output json

  emit security-groups "Security groups" '.SecurityGroups' '.GroupId' \
    'ID\tName\tVPC' \
    '.GroupId, .GroupName, .VpcId' \
    aws ec2 describe-security-groups --region "$region" --output json

  emit route-tables "Route tables" '.RouteTables' '.RouteTableId' \
    'ID\tVPC\tMain\tAssoc\tRoutes' \
    '.RouteTableId, .VpcId, ([.Associations[].Main] | any), (.Associations | length), (.Routes | length)' \
    aws ec2 describe-route-tables --region "$region" --output json

  emit internet-gateways "Internet gateways" '.InternetGateways' '.InternetGatewayId' \
    'ID\tAttachedVPC\tState' \
    '.InternetGatewayId, (.Attachments[0].VpcId // "-"), (.Attachments[0].State // "-")' \
    aws ec2 describe-internet-gateways --region "$region" --output json

  emit nat-gateways "NAT gateways" '.NatGateways' '.NatGatewayId' \
    'ID\tVPC\tSubnet\tState\tType' \
    '.NatGatewayId, .VpcId, .SubnetId, .State, (.ConnectivityType // "-")' \
    aws ec2 describe-nat-gateways --region "$region" --output json

  emit elastic-ips "Elastic IPs" '.Addresses' '(.AllocationId // .PublicIp)' \
    'AllocationId\tPublicIP\tInstance\tPrivateIP' \
    '(.AllocationId // "-"), (.PublicIp // "-"), (.InstanceId // "-"), (.PrivateIpAddress // "-")' \
    aws ec2 describe-addresses --region "$region" --output json

  emit network-acls "Network ACLs" '.NetworkAcls' '.NetworkAclId' \
    'ID\tVPC\tDefault\tSubnets\tEntries' \
    '.NetworkAclId, .VpcId, .IsDefault, (.Associations | length), (.Entries | length)' \
    aws ec2 describe-network-acls --region "$region" --output json

  emit vpc-endpoints "VPC endpoints" '.VpcEndpoints' '.VpcEndpointId' \
    'ID\tVPC\tService\tType\tState' \
    '.VpcEndpointId, .VpcId, .ServiceName, .VpcEndpointType, .State' \
    aws ec2 describe-vpc-endpoints --region "$region" --output json

  emit vpc-peering "VPC peering connections" '.VpcPeeringConnections' '.VpcPeeringConnectionId' \
    'ID\tRequesterVPC\tAccepterVPC\tStatus' \
    '.VpcPeeringConnectionId, .RequesterVpcInfo.VpcId, .AccepterVpcInfo.VpcId, .Status.Code' \
    aws ec2 describe-vpc-peering-connections --region "$region" --output json

  emit ebs "EBS volumes" '.Volumes' '.VolumeId' \
    'ID\tSize\tState\tAttached' \
    '.VolumeId, .Size, .State, (.Attachments[0].InstanceId // "-")' \
    aws ec2 describe-volumes --region "$region" --output json

  emit efs "EFS file systems" '.FileSystems' '.FileSystemId' \
    'ID\tName\tState\tSize' \
    '.FileSystemId, (.Name // "-"), .LifeCycleState, .SizeInBytes.Value' \
    aws efs describe-file-systems --region "$region" --output json

  emit rds "RDS instances" '.DBInstances' '.DBInstanceIdentifier' \
    'ID\tEngine\tClass\tStatus' \
    '.DBInstanceIdentifier, .Engine, .DBInstanceClass, .DBInstanceStatus' \
    aws rds describe-db-instances --region "$region" --output json

  emit lambda "Lambda functions" '.Functions' '.FunctionName' \
    'Name\tRuntime\tMemory\tLastModified' \
    '.FunctionName, (.Runtime // "-"), .MemorySize, .LastModified' \
    aws lambda list-functions --region "$region" --output json

  emit elb "Load balancers (ALB/NLB)" '.LoadBalancers' '.LoadBalancerName' \
    'Name\tType\tScheme\tState\tDNS' \
    '.LoadBalancerName, .Type, .Scheme, .State.Code, .DNSName' \
    aws elbv2 describe-load-balancers --region "$region" --output json

  emit cw-alarms "CloudWatch alarms" '.MetricAlarms' '.AlarmName' \
    'Name\tState\tMetric\tNamespace' \
    '.AlarmName, .StateValue, (.MetricName // "-"), (.Namespace // "-")' \
    aws cloudwatch describe-alarms --region "$region" --output json

  emit cw-log-groups "CloudWatch log groups" '.logGroups' '.logGroupName' \
    'Name\tRetentionDays\tStoredBytes' \
    '.logGroupName, (.retentionInDays // "-"), (.storedBytes // 0)' \
    aws logs describe-log-groups --region "$region" --output json

  emit ebs-snapshots "EBS snapshots (owned)" '.Snapshots' '.SnapshotId' \
    'ID\tVolume\tSize\tState\tStarted' \
    '.SnapshotId, (.VolumeId // "-"), .VolumeSize, .State, .StartTime' \
    aws ec2 describe-snapshots --owner-ids self --region "$region" --output json

  emit ec2-key-pairs "EC2 key pairs" '.KeyPairs' '.KeyName' \
    'Name\tID\tType' \
    '.KeyName, (.KeyPairId // "-"), (.KeyType // "-")' \
    aws ec2 describe-key-pairs --region "$region" --output json

  emit cloudformation "CloudFormation stacks" '.Stacks' '.StackName' \
    'Name\tStatus\tCreated' \
    '.StackName, .StackStatus, .CreationTime' \
    aws cloudformation describe-stacks --region "$region" --output json

  emit dlm-policies "DLM lifecycle policies" '.Policies' '.PolicyId' \
    'ID\tState\tDescription' \
    '.PolicyId, .State, (.Description // "-")' \
    aws dlm get-lifecycle-policies --region "$region" --output json

  emit servicediscovery "Service Discovery namespaces" '(.Namespaces // [])' '.Id' \
    'ID\tName\tType' \
    '.Id, .Name, .Type' \
    aws servicediscovery list-namespaces --region "$region" --output json

  emit lightsail-keys "Lightsail key pairs" '(.keyPairs // [])' '.name' \
    'Name\tFingerprint\tCreated' \
    '.name, (.fingerprint // "-"), .createdAt' \
    aws lightsail get-key-pairs --region "$region" --output json

  emit_deep dynamodb "DynamoDB tables" '.TableNames[]' '.Table' 'true' '.TableName' \
    'Name\tItems\tSizeBytes\tStatus' \
    '.TableName, .ItemCount, .TableSizeBytes, .TableStatus' \
    aws dynamodb list-tables --region "$region" --output json \
    -- \
    aws dynamodb describe-table --table-name '{}' --region "$region" --output json

  emit_deep acm "ACM certificates" '.CertificateSummaryList[].CertificateArn' '.Certificate' 'true' '.CertificateArn' \
    'Domain\tStatus\tType\tNotAfter' \
    '.DomainName, .Status, .Type, (.NotAfter // "-")' \
    aws acm list-certificates --region "$region" --output json \
    -- \
    aws acm describe-certificate --certificate-arn '{}' --region "$region" --output json

  emit_deep kms "KMS keys (customer-managed)" '.Keys[].KeyId' '.KeyMetadata' '.KeyManager == "CUSTOMER"' '.KeyId' \
    'ID\tState\tUsage\tDescription' \
    '.KeyId, .KeyState, .KeyUsage, (.Description // "-")' \
    aws kms list-keys --region "$region" --output json \
    -- \
    aws kms describe-key --key-id '{}' --region "$region" --output json

  region_end
done

note ""
hr >&2
note "Done."
