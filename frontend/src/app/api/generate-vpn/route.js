import { NextResponse } from 'next/server';
import fs from 'fs';
import path from 'path';

// Paths inside the Docker container where files are mounted
const PKI_DIR = '/etc/openvpn/pki';
const TEMPLATE_PATH = '/etc/openvpn/client.ovpn.template';

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  let username = searchParams.get('username') || 'hacker-profile';

  // Sanitize username to prevent path traversal or invalid characters in filename
  username = username.replace(/[^a-zA-Z0-9_-]/g, '').substring(0, 32);

  try {
    // 1. Read PKI files from mounted paths
    // Fallback paths for local development if run outside container
    const caPath = fs.existsSync(path.join(PKI_DIR, 'ca.crt')) 
      ? path.join(PKI_DIR, 'ca.crt') 
      : path.resolve('../docker/config/pki/ca.crt');

    const certPath = fs.existsSync(path.join(PKI_DIR, 'client.crt'))
      ? path.join(PKI_DIR, 'client.crt')
      : path.resolve('../docker/config/pki/client.crt');

    const keyPath = fs.existsSync(path.join(PKI_DIR, 'client.key'))
      ? path.join(PKI_DIR, 'client.key')
      : path.resolve('../docker/config/pki/client.key');

    const tlsCryptPath = fs.existsSync(path.join(PKI_DIR, 'tls-crypt.key'))
      ? path.join(PKI_DIR, 'tls-crypt.key')
      : path.resolve('../docker/config/pki/tls-crypt.key');

    const templatePath = fs.existsSync(TEMPLATE_PATH)
      ? TEMPLATE_PATH
      : path.resolve('../docker/config/client.ovpn.template');

    // 2. Check if all required files exist
    const missingFiles = [];
    if (!fs.existsSync(caPath)) missingFiles.push('ca.crt');
    if (!fs.existsSync(certPath)) missingFiles.push('client.crt');
    if (!fs.existsSync(keyPath)) missingFiles.push('client.key');
    if (!fs.existsSync(tlsCryptPath)) missingFiles.push('tls-crypt.key');
    if (!fs.existsSync(templatePath)) missingFiles.push('client.ovpn.template');

    if (missingFiles.length > 0) {
      return NextResponse.json(
        { 
          error: 'Configuration files missing on server', 
          details: `Missing files: ${missingFiles.join(', ')}` 
        }, 
        { status: 500 }
      );
    }

    // 3. Load files
    const caContent = fs.readFileSync(caPath, 'utf8');
    const certContent = fs.readFileSync(certPath, 'utf8');
    const keyContent = fs.readFileSync(keyPath, 'utf8');
    const tlsCryptContent = fs.readFileSync(tlsCryptPath, 'utf8');
    let templateContent = fs.readFileSync(templatePath, 'utf8');

    // 4. Inject certificates and keys into client profile
    // Replace standard template blocks
    templateContent = templateContent.replace(/<ca>[\s\S]*?<\/ca>/, `<ca>\n${caContent.trim()}\n</ca>`);
    templateContent = templateContent.replace(/<cert>[\s\S]*?<\/cert>/, `<cert>\n${certContent.trim()}\n</cert>`);
    templateContent = templateContent.replace(/<key>[\s\S]*?<\/key>/, `<key>\n${keyContent.trim()}\n</key>`);
    templateContent = templateContent.replace(/<tls-crypt>[\s\S]*?<\/tls-crypt>/, `<tls-crypt>\n${tlsCryptContent.trim()}\n</tls-crypt>`);

    // 5. Generate Response headers for downloading the file
    const headers = new Headers();
    headers.set('Content-Type', 'application/x-openvpn-profile');
    headers.set('Content-Disposition', `attachment; filename="${username}.ovpn"`);

    return new Response(templateContent, {
      status: 200,
      headers
    });

  } catch (error) {
    console.error('Error generating OVPN file:', error);
    return NextResponse.json(
      { error: 'Internal server error', details: error.message },
      { status: 500 }
    );
  }
}
