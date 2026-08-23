import logging
import os
import sys

import psycopg2
from dotenv import load_dotenv
from flask import Flask, g, jsonify, request
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from prometheus_client.core import GaugeMetricFamily
from psycopg2.extras import RealDictCursor
from psycopg2.pool import SimpleConnectionPool

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

load_dotenv()

app = Flask(__name__)

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    log.critical("Erro: DATABASE_URL não definida.")
    sys.exit(1)

try:
    # cursor_factory definido na conexão (e não em cada cursor()) para que a
    # instrumentação OpenTelemetry do psycopg2, que substitui a factory padrão
    # da conexão por uma versão rastreada, não seja contornada.
    pool = SimpleConnectionPool(1, 10, dsn=DATABASE_URL, cursor_factory=RealDictCursor)
    log.info("Pool de conexões com o PostgreSQL (ngo-service) inicializado.")
except psycopg2.Error as e:
    log.critical(f"Erro ao conectar ao PostgreSQL: {e}")
    sys.exit(1)

@app.after_request
def log_request(response):
    if request.path not in ('/health', '/metrics'):
        # g.log_detail é preenchido pelos handlers com dados da requisição (ex.: nome da ONG)
        # trace_id correlaciona a linha de log com o trace no Tempo; fica vazio quando o SDK OTel está desativado
        ctx = trace.get_current_span().get_span_context()
        trace_ref = f' trace_id={ctx.trace_id:032x}' if ctx.is_valid else ''
        log.info(f"{request.method} {request.path} -> {response.status_code}{g.get('log_detail', '')}{trace_ref}")
    return response

@app.route('/health')
def health():
    return jsonify({"status": "ok", "service": "ngo-service"})

@app.route('/ngos', methods=['POST'])
def create_ngo():
    data = request.get_json()
    nome = data.get('name', '?') if isinstance(data, dict) else '?'
    g.log_detail = f' | ong="{nome}"'
    span = trace.get_current_span()
    if span.is_recording():
        span.set_attribute("ngo.name", nome)
    if not data or not all(k in data for k in ('name', 'email', 'cause', 'city')):
        return jsonify({"error": "Campos obrigatórios ausentes"}), 400

    conn = pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO ngos (name, email, cause, city) VALUES (%s, %s, %s, %s) RETURNING *",
                (data['name'], data['email'], data['cause'], data['city'])
            )
            new_ngo = cur.fetchone()
            conn.commit()
            g.log_detail = f' | ong="{nome}" id={new_ngo["id"]}'
            if span.is_recording():
                span.set_attribute("ngo.id", new_ngo["id"])
            return jsonify(new_ngo), 201
    except psycopg2.IntegrityError:
        conn.rollback()
        return jsonify({"error": "E-mail já cadastrado"}), 409
    except psycopg2.Error as e:
        conn.rollback()
        log.error(f"Erro ao criar ONG: {e}")
        return jsonify({"error": "Erro interno"}), 500
    finally:
        pool.putconn(conn)

@app.route('/ngos', methods=['GET'])
def get_ngos():
    conn = pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM ngos ORDER BY id DESC")
            return jsonify(cur.fetchall()), 200
    except psycopg2.Error as e:
        log.error(f"Erro ao buscar ONGs: {e}")
        return jsonify({"error": "Erro interno"}), 500
    finally:
        pool.putconn(conn)

class NgoMetricsCollector:
    # Consulta o total direto no Postgres a cada coleta do Prometheus (em vez de
    # manter um contador em memória), para o valor nunca divergir do estado real
    # da tabela - a mesma divergência que motivou esta métrica quando o total
    # vinha de um painel Grafana baseado em contagem de linhas de log no Loki.
    def collect(self):
        conn = pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) AS total FROM ngos")
                total = cur.fetchone()['total']
        finally:
            pool.putconn(conn)
        gauge = GaugeMetricFamily('solidarytech_ngos_total', 'Total de ONGs cadastradas na plataforma')
        gauge.add_metric([], total)
        yield gauge

metrics_registry = CollectorRegistry()
metrics_registry.register(NgoMetricsCollector())

@app.route('/metrics')
def metrics():
    return generate_latest(metrics_registry), 200, {'Content-Type': CONTENT_TYPE_LATEST}

if __name__ == '__main__':
    port = int(os.getenv("PORT", "8081"))
    app.run(host='0.0.0.0', port=port)