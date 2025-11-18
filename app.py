from flask import Flask, render_template, jsonify
import socket
import os
import sys

app = Flask(__name__)

# Request counter for demonstration
request_count = 0

@app.route('/')
def home():
    """
    Main route - serves your portfolio website
    """
    global request_count
    request_count += 1
    return render_template('index.html')

@app.route('/health')
def health():
    """
    Health check endpoint for AWS ECS
    Returns 200 OK if the container is healthy
    """
    return jsonify({
        'status': 'healthy',
        'service': 'Portfolio Flask App',
        'requests_served': request_count
    }), 200

@app.route('/info')
def info():
    """
    Container information endpoint
    Shows details about the running container
    """
    return jsonify({
        'container_hostname': socket.gethostname(),
        'total_requests': request_count,
        'python_version': sys.version.split()[0],
        'flask_version': '3.0.0',
        'environment': os.getenv('ENVIRONMENT', 'AWS ECS Fargate'),
        'platform': sys.platform,
        'status': 'running'
    }), 200

@app.route('/api/status')
def api_status():
    """
    API status endpoint
    Can be used for monitoring
    """
    return jsonify({
        'api': 'online',
        'version': '1.0.0',
        'uptime': 'active',
        'hostname': socket.gethostname()
    }), 200

if __name__ == '__main__':
    # Run Flask app
    # host='0.0.0.0' makes it accessible from outside the container
    # port=5000 is the standard Flask port
    print("=" * 50)
    print("🚀 Flask Portfolio App Starting...")
    print(f"🐍 Python Version: {sys.version.split()[0]}")
    print(f"🖥️  Hostname: {socket.gethostname()}")
    print(f"🌐 Server will run on http://0.0.0.0:5000")
    print("=" * 50)
    
    app.run(
        host='0.0.0.0',  # Listen on all network interfaces
        port=5000,        # Port 5000 (Flask default)
        debug=False       # Production mode (no debug)
    )