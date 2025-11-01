# Netbird Self Hosted Configuration Template

- Clone netbird github repository

- populate setup.env files and generate management.json and other config files

- Generate certs for your target domain using certbot and update it in values.yml file

- update files in values.yml for helm

- Generate IDP secrets following steps from the [docs](https://docs.netbird.io/selfhosted/identity-providers#google-workspace) and update in values.yml file

- Install and update helm repo

  ```bash
  helm repo add https://dmdhrumilmistry.github.io/helm-charts
  helm repo update
  ```

- Search and install repo

  ```bash
  helm search repo netbird
  ```

- Install netbird self hosted stack with custom values

  ```bash
  helm install netbird dmdhrumilmistry/netbird -f values.yml
  ```

