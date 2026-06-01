# Poswiadczenia i URL czytane ze zmiennych srodowiskowych:
#   ROS_HOSTURL, ROS_USERNAME, ROS_PASSWORD, ROS_INSECURE
# Wstrzykiwane przez `sops exec-env` z secrets.sops.yaml.
# insecure=true (cert self-signed) - pozniej weryfikacja CA.
provider "routeros" {}
