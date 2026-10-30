variable "stage" {
  type    = number
  default = 1
}

resource "terraform_data" "service" {
  input = var.stage == 1 ? {
    name     = "gazette"
    port     = 8080
    replicas = 2
    tags     = { Team = "platform", Env = "stage" }
    command  = ["serve", "--http"]
    policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "s3:GetObject" }] })
    script   = "#!/bin/sh\necho start\nexec gazette\n"
    } : {
    name     = "gazette"
    port     = 9090
    replicas = 2
    tags     = { Team = "platform", Env = "stage", Owner = "relay" }
    command  = ["serve", "--grpc"]
    policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"] }] })
    script   = "#!/bin/sh\necho start\nexec gazette --grpc\n"
  }
}

resource "terraform_data" "old_queue" {
  count = var.stage == 1 ? 1 : 0
  input = { name = "relay-queue", retention = 4 }
}

resource "terraform_data" "listener" {
  count = var.stage == 1 ? 0 : 1
  input = { port = 9090, protocol = "GRPC" }
}

resource "terraform_data" "dns" {
  input            = "gazette.internal"
  triggers_replace = var.stage
}

output "endpoint" {
  value = var.stage == 1 ? "http://gazette:8080" : "grpc://gazette:9090"
}
