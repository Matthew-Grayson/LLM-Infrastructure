run:
cp .env.example .env

edit .env and fill values
set -a; source .env; set +a
terraform init
terraform apply -auto-approve
