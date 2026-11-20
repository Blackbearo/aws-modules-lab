output "alb_dns" {
  value = module.web_tier.alb_dns
}

output "rds_endpoint" {
  value = module.db.endpoint
}
