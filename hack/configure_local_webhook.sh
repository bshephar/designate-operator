#!/bin/bash
set -ex

TMPDIR=${TMPDIR:-"/tmp/k8s-webhook-server/serving-certs"}
SKIP_CERT=${SKIP_CERT:-false}
CRC_IP=${CRC_IP:-$(/sbin/ip -o -4 addr list crc | awk '{print $4}' | cut -d/ -f1)}

#Open 9443
sudo firewall-cmd --zone=libvirt --add-port=9443/tcp
sudo firewall-cmd --runtime-to-permanent

# Generate the certs and the ca bundle
if [ "$SKIP_CERT" = false ] ; then
    mkdir -p ${TMPDIR}
    rm -rf ${TMPDIR}/* || true

    openssl req -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/CN=${HOSTNAME}" \
        -addext "subjectAltName = IP:${CRC_IP}" \
        -keyout ${TMPDIR}/tls.key \
        -out ${TMPDIR}/tls.crt

    cat ${TMPDIR}/tls.crt ${TMPDIR}/tls.key | base64 -w 0 > ${TMPDIR}/bundle.pem

fi

CA_BUNDLE=`cat ${TMPDIR}/bundle.pem`

# Patch the webhook(s)
cat >> ${TMPDIR}/patch_webhook_configurations.yaml <<EOF_CAT
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: vdesignate.kb.io
webhooks:
- admissionReviewVersions:
  - v1
  clientConfig:
    caBundle: ${CA_BUNDLE}
    url: https://${CRC_IP}:9443/validate-designate-openstack-org-v1beta1-designate
  failurePolicy: Fail
  matchPolicy: Equivalent
  name: vdesignate.kb.io
  objectSelector: {}
  rules:
  - apiGroups:
    - designate.openstack.org
    apiVersions:
    - v1beta1
    operations:
    - CREATE
    - UPDATE
    resources:
    - designates
    scope: '*'
  sideEffects: None
  timeoutSeconds: 10
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: mdesignate.kb.io
webhooks:
- admissionReviewVersions:
  - v1
  clientConfig:
    caBundle: ${CA_BUNDLE}
    url: https://${CRC_IP}:9443/mutate-designate-openstack-org-v1beta1-designate
  failurePolicy: Fail
  matchPolicy: Equivalent
  name: mdesignate.kb.io
  objectSelector: {}
  rules:
  - apiGroups:
    - designate.openstack.org
    apiVersions:
    - v1beta1
    operations:
    - CREATE
    - UPDATE
    resources:
    - designates
    scope: '*'
  sideEffects: None
  timeoutSeconds: 10
EOF_CAT

oc apply -n openstack -f ${TMPDIR}/patch_webhook_configurations.yaml

# Scale-down operator deployment replicas to zero and remove OLM webhooks
CSV_NAME="$(oc get csv -n openstack-operators -l operators.coreos.com/designate-operator.openstack-operators -o name)"

if [ -n "${CSV_NAME}" ]; then
    oc patch "${CSV_NAME}" -n openstack-operators --type=json -p="[{'op': 'replace', 'path': '/spec/install/spec/deployments/0/spec/replicas', 'value': 0}]"
    oc patch "${CSV_NAME}" -n openstack-operators --type=json -p="[{'op': 'replace', 'path': '/spec/webhookdefinitions', 'value': []}]"
fi
