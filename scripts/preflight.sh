#!/usr/bin/env bash
# Checks a subscription before the first apply: signed in, resource providers
# registered, and quota/SKU visible in the target region.
# Usage: scripts/preflight.sh [location] [iothub_location]
#        defaults: malaysiawest southeastasia
set -euo pipefail

LOCATION="${1:-malaysiawest}"
IOT_LOCATION="${2:-southeastasia}"

PROVIDERS=(
  Microsoft.App
  Microsoft.Cdn
  Microsoft.Devices
  Microsoft.DBforMySQL
  Microsoft.ContainerRegistry
  Microsoft.KeyVault
  Microsoft.MachineLearningServices
  Microsoft.Network
  Microsoft.OperationalInsights
  Microsoft.Insights
  Microsoft.Storage
  Microsoft.Web
  Microsoft.PolicyInsights
  Microsoft.Consumption
)

echo "== Subscription =="
az account show --query "{name:name, id:id, state:state}" -o table

echo
echo "== Resource providers =="
for ns in "${PROVIDERS[@]}"; do
  state=$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [[ "$state" != "Registered" ]]; then
    echo "registering $ns (was $state)"
    az provider register --namespace "$ns" >/dev/null
  else
    echo "ok          $ns"
  fi
done
echo "Registration can take a few minutes. Re-run this script until every line says ok."

echo
echo "== MySQL Flexible Server B1ms in $LOCATION =="
# A plain text search: the shape of list-skus output differs between CLI versions.
if az mysql flexible-server list-skus --location "$LOCATION" -o json 2>/dev/null | grep -qi "Standard_B1ms"; then
  echo "ok: Standard_B1ms is offered in $LOCATION"
else
  echo "Standard_B1ms NOT found in $LOCATION (or the SKU list could not be read)"
fi

echo
echo "== vCPU quota in $LOCATION (Azure ML training needs the DSv2 family) =="
az vm list-usage --location "$LOCATION" \
  --query "[?contains(name.value, 'standardDSv2Family') || name.value=='cores' || contains(name.value, 'Dynamic')].{name:name.localizedValue, used:currentValue, limit:limit}" \
  -o table || echo "could not read quota"

echo
echo
echo "== IoT Hub in $IOT_LOCATION =="
# The provider lists display names ("Southeast Asia"), so compare without spaces or case.
want=$(echo "$IOT_LOCATION" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
if az provider show -n Microsoft.Devices --query "resourceTypes[?resourceType=='IotHubs'].locations | [0]" -o tsv 2>/dev/null      | tr -d ' ' | tr '[:upper:]' '[:lower:]' | grep -qx "$want"; then
  echo "ok: IoT Hub is listed for $IOT_LOCATION"
else
  echo "IoT Hub is NOT listed for $IOT_LOCATION; pick another region for iothub_location"
fi

echo "A limit of 0 means a quota request is needed before that feature can be enabled."
echo "Also check your credit and expiry: Cost Management -> Credits."
