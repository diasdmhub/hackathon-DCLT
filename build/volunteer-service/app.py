import logging
import os
import sys
import time
import uuid

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from dotenv import load_dotenv
from flask import Flask, g, jsonify, request
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from prometheus_client.core import GaugeMetricFamily

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

load_dotenv()

app = Flask(__name__)

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
DYNAMODB_TABLE = os.getenv("AWS_DYNAMODB_TABLE")
AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL") or None  # permite apontar para um emulador local (ex: DynamoDB Local) em vez da AWS real

if not DYNAMODB_TABLE:
    log.critical("Erro: AWS_DYNAMODB_TABLE não definida.")
    sys.exit(1)

try:
    dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION, endpoint_url=AWS_ENDPOINT_URL)
    table = dynamodb.Table(DYNAMODB_TABLE)
    log.info(f"Conectado à tabela DynamoDB: {DYNAMODB_TABLE}")
except (BotoCoreError, ClientError) as e:
    log.critical(f"Falha ao conectar no DynamoDB: {e}")
    sys.exit(1)

@app.after_request
def log_request(response):
    if request.path not in ('/health', '/metrics'):
        # g.log_detail é preenchido pelos handlers com dados da requisição (ex.: nome do voluntário)
        # trace_id correlaciona a linha de log com o trace no Tempo; fica vazio quando o SDK OTel está desativado
        ctx = trace.get_current_span().get_span_context()
        trace_ref = f' trace_id={ctx.trace_id:032x}' if ctx.is_valid else ''
        log.info(f"{request.method} {request.path} -> {response.status_code}{g.get('log_detail', '')}{trace_ref}")
    return response

@app.route('/health')
def health():
    return jsonify({"status": "ok", "service": "volunteer-service"})

@app.route('/volunteers', methods=['POST'])
def register_volunteer():
    data = request.get_json()
    if isinstance(data, dict):
        g.log_detail = f' | voluntario="{data.get("name", "?")}" ngo_id={data.get("ngo_id", "?")}'
    if not data or not all(k in data for k in ('name', 'email', 'ngo_id')):
        return jsonify({"error": "Campos obrigatórios ausentes"}), 400

    try:
        ngo_id = int(data['ngo_id'])
    except (TypeError, ValueError):
        return jsonify({"error": "ngo_id inválido"}), 400

    span = trace.get_current_span()
    if span.is_recording():
        span.set_attribute("volunteer.name", data['name'])
        span.set_attribute("volunteer.ngo_id", ngo_id)

    volunteer_id = str(uuid.uuid4())
    item = {
        'volunteer_id': volunteer_id,
        'name': data['name'],
        'email': data['email'],
        'ngo_id': ngo_id,
        'registered_at': str(int(time.time()))
    }
    
    try:
        table.put_item(Item=item)
        return jsonify(item), 201
    except (BotoCoreError, ClientError) as e:
        log.error(f"Erro ao salvar voluntário no DynamoDB: {e}")
        return jsonify({"error": "Erro interno ao processar dados"}), 500

@app.route('/volunteers/<int:ngo_id>', methods=['GET'])
def get_volunteers_by_ngo(ngo_id):
    try:
        # Nota para avaliação dos alunos: Operação Scan simplificada para fins de desenvolvimento.
        # Em cenários complexos de produção, índices globais secundários (GSI) seriam exigidos.
        response = table.scan(
            FilterExpression=boto3.dynamodb.conditions.Attr('ngo_id').eq(ngo_id)
        )
        return jsonify(response.get('Items', [])), 200
    except (BotoCoreError, ClientError) as e:
        log.error(f"Erro ao buscar dados no DynamoDB: {e}")
        return jsonify({"error": "Erro interno"}), 500

class VolunteerMetricsCollector:
    # Scan completo da tabela a cada coleta do Prometheus, Select='COUNT' evita
    # transferir os itens (só a contagem), mas ainda consome as mesmas RCUs de
    # um scan normal - por isso este endpoint é coletado num job à parte, com
    # intervalo de 5m em vez do padrão de 15s (ver observe/040-prometheus/prometheus.yml),
    # para não competir com a capacidade provisionada da tabela (5 RCU).
    def collect(self):
        total = 0
        scan_kwargs = {'Select': 'COUNT'}
        while True:
            response = table.scan(**scan_kwargs)
            total += response['Count']
            last_key = response.get('LastEvaluatedKey')
            if not last_key:
                break
            scan_kwargs['ExclusiveStartKey'] = last_key
        gauge = GaugeMetricFamily('solidarytech_volunteers_total', 'Total de voluntários cadastrados na plataforma')
        gauge.add_metric([], total)
        yield gauge

metrics_registry = CollectorRegistry()
metrics_registry.register(VolunteerMetricsCollector())

@app.route('/metrics')
def metrics():
    return generate_latest(metrics_registry), 200, {'Content-Type': CONTENT_TYPE_LATEST}

if __name__ == '__main__':
    port = int(os.getenv("PORT", "8083"))
    app.run(host='0.0.0.0', port=port)