# NLB única compartilhada pelos 3 microsserviços - equivalente ao IP fixo
# compartilhado via MetalLB (`allow-shared-ip`) usado em kubeadm-local, mas
# como recurso de primeira classe do Terraform em vez de originado por um
# Service type=LoadBalancer. Um listener por serviço (mesmas portas de
# sempre: 8081/8082/8083), cada um encaminhando para o target group
# correspondente. Os alvos (IPs de pod) são registrados pelo AWS Load
# Balancer Controller via TargetGroupBinding, não pelo ciclo de vida do
# Service - ver kube-aws/README.md e terra/modules/lb-controller.
locals {
  services = {
    ngo       = { port = 8081 }
    donation  = { port = 8082 }
    volunteer = { port = 8083 }
  }
}

resource "aws_lb" "solidarytech" {
  name               = "${var.name_prefix}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids

  tags = { Name = "${var.name_prefix}-nlb" }
}

resource "aws_lb_target_group" "services" {
  for_each = local.services

  name        = "${var.name_prefix}-${each.key}-tg"
  port        = each.value.port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Health check HTTP no /health de cada serviço, mesmo com o target group
  # sendo TCP (a NLB suporta health check HTTP/HTTPS em target group TCP).
  health_check {
    protocol            = "HTTP"
    path                = "/health"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.name_prefix}-${each.key}-tg" }
}

resource "aws_lb_listener" "services" {
  for_each = local.services

  load_balancer_arn = aws_lb.solidarytech.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services[each.key].arn
  }
}

# A NLB não tem Security Group próprio (diferente da ALB); com target_type
# "ip" o tráfego chega às pods preservando o IP de origem e passa direto pelo
# Security Group do cluster EKS (compartilhado por nodes/pods). Sem esta
# regra, o tráfego da internet para a NLB seria aceito mas descartado ao
# tentar alcançar o pod.
resource "aws_security_group_rule" "nlb_ingress" {
  for_each = local.services

  security_group_id = var.cluster_security_group_id
  type              = "ingress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "NLB para ${each.key}-service (${each.value.port})"
}
