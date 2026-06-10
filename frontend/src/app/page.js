'use client';

import React, { useState, useEffect } from 'react';

// Lists for generating random hacker-like usernames
const PREFIXES = ['Ghost', 'Specter', 'Cipher', 'Viper', 'Phreak', 'Root', 'Null', 'Daemon', 'Crypt', 'Zero', 'Shadow', 'Vector', 'Pixel', 'Binary'];
const SUFFIXES = ['Hacker', 'Ninja', 'Sec', 'Root', 'Byte', 'Shell', 'Buffer', 'Net', 'Crypt', 'Overlord', 'Ghost', 'Kernel', 'Node', 'Admin'];

export default function Home() {
  const [username, setUsername] = useState('');
  const [downloading, setDownloading] = useState(false);
  const [node1Status, setNode1Status] = useState('ONLINE');
  const [node2Status, setNode2Status] = useState('ONLINE');
  const [lbStatus, setLbStatus] = useState('ONLINE');

  // Generate a random username on mount
  useEffect(() => {
    generateRandomUser();
  }, []);

  const generateRandomUser = () => {
    const pref = PREFIXES[Math.floor(Math.random() * PREFIXES.length)];
    const suff = SUFFIXES[Math.floor(Math.random() * SUFFIXES.length)];
    const num = Math.floor(1000 + Math.random() * 9000);
    setUsername(`${pref}-${suff}-${num}`);
  };

  const handleDownload = async () => {
    if (!username) return;
    setDownloading(true);
    
    try {
      const response = await fetch(`/api/generate-vpn?username=${encodeURIComponent(username)}`);
      
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.details || 'Falla al compilar el certificado');
      }

      // Convert response to a blob and trigger download
      const blob = await response.blob();
      const url = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.setAttribute('download', `${username}.ovpn`);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      window.URL.revokeObjectURL(url);
    } catch (error) {
      alert(`Error: ${error.message}`);
    } finally {
      setDownloading(false);
    }
  };

  return (
    <main className="main-wrapper">
      <div className="glow-background"></div>
      
      <div className="portal-container">
        <header className="portal-header">
          <div className="status-indicator-container">
            <span className="pulse-dot"></span>
            <span className="status-text">SECURE GATEWAY</span>
          </div>
          <h1>CTF VPN ACCESS PORTAL</h1>
          <p className="description">
            Genera tus credenciales de acceso y descarga el perfil OpenVPN configurado para conectarte a nuestra red de retos (HTB-Style).
          </p>
        </header>

        {/* Dashboard Grid */}
        <div className="dashboard-grid">
          
          {/* Card 1: User Profile Generator */}
          <div className="portal-card user-card">
            <div className="card-header">
              <h2>1. Perfil de Jugador</h2>
              <p>Genera un handle de hacker aleatorio para tu certificado VPN.</p>
            </div>
            
            <div className="username-display-wrapper">
              <div className="username-display">
                <code>{username || 'Cargando...'}</code>
              </div>
              <button 
                type="button" 
                onClick={generateRandomUser} 
                className="btn-secondary"
                title="Generar nuevo usuario"
              >
                🔄 Nuevo
              </button>
            </div>

            <button 
              type="button"
              onClick={handleDownload} 
              disabled={downloading || !username}
              className="btn-primary"
            >
              {downloading ? (
                <>
                  <span className="spinner"></span> Compilando...
                </>
              ) : (
                '📥 Descargar Configuración (.ovpn)'
              )}
            </button>
          </div>

          {/* Card 2: Cluster Network Status */}
          <div className="portal-card status-card">
            <div className="card-header">
              <h2>2. Estado del Cluster VPN</h2>
              <p>Monitoreo activo de la infraestructura activo-activo.</p>
            </div>

            <div className="status-list">
              <div className="status-item">
                <span className="status-label">HAProxy Load Balancer</span>
                <span className="status-pill pill-online">
                  <span className="dot"></span> {lbStatus}
                </span>
              </div>
              <div className="status-item">
                <span className="status-label">OpenVPN Server - Nodo 1</span>
                <span className="status-pill pill-online">
                  <span className="dot"></span> {node1Status}
                </span>
              </div>
              <div className="status-item">
                <span className="status-label">OpenVPN Server - Nodo 2</span>
                <span className="status-pill pill-online">
                  <span className="dot"></span> {node2Status}
                </span>
              </div>
            </div>

            <div className="card-footer-info">
              <span className="info-icon">ℹ️</span>
              <p className="info-text">
                El balanceador distribuye el tráfico utilizando Sticky Sessions basadas en tu IP pública hacia el nodo con menor carga.
              </p>
            </div>
          </div>
        </div>

        <footer className="portal-footer">
          <p>
            Requerimientos mínimos: <strong>OpenVPN Client 2.6+</strong>. Cifrado simétrico: <strong>AES-256-GCM</strong>.
          </p>
          <p className="privacy-note">
            🛡️ <strong>Aviso de Privacidad y Auditoría:</strong> Este portal no recopila, almacena ni registra tus datos personales ni tus direcciones IP. Los perfiles VPN se compilan de forma efímera en memoria en tiempo de descarga y no se guarda registro en el servidor de las claves de cliente ni de las identidades aleatorias generadas.
          </p>
        </footer>
      </div>
    </main>
  );
}
