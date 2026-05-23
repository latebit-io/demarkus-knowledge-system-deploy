terraform {
  backend "gcs" {
    # Replace with the hand-created state bucket name.
    bucket = "REPLACE_ME"
    prefix = "knowledge-system/prod"
  }
}
