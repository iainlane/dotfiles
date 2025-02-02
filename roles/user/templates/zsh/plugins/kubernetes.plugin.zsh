# Pick up all Kubernetes configs in ~/.kube/config

# Set the default kube context if present
typeset DEFAULT_KUBE_CONTEXTS="${HOME}/.kube/config"
[[ -f ${DEFAULT_KUBE_CONTEXTS} ]] && export KUBECONFIG="${DEFAULT_KUBE_CONTEXTS}"

# Add additional configs from ~/.kube/configs directory
typeset CUSTOM_KUBE_CONTEXTS="${HOME}/.kube/configs"
mkdir -p "${CUSTOM_KUBE_CONTEXTS}"

# Use zsh glob qualifier (N) for null_glob and expansion
for config in ${CUSTOM_KUBE_CONTEXTS}/config*(N); do
  KUBECONFIG+="${KUBECONFIG:+:}${config}"
done
export KUBECONFIG
