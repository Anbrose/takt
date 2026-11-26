import { Storage } from '@google-cloud/storage';
import type { AudioStore } from './audio-store.ts';

const UPLOAD_TTL_MS = 7 * 24 * 3600 * 1000;

/** Audio in a GCS bucket; the phone talks to GCS directly via resumable-session and signed URLs. */
export class GcsAudioStore implements AudioStore {
  private readonly bucket;

  constructor(bucketName: string, storage: Storage = new Storage()) {
    this.bucket = storage.bucket(bucketName);
  }

  async createUpload(object: string, contentType: 'audio/mp4') {
    const [uploadUrl] = await this.bucket.file(object).createResumableUpload({ metadata: { contentType } });
    return { uploadUrl, expiresAt: new Date(Date.now() + UPLOAD_TTL_MS) };
  }

  async stat(object: string) {
    try {
      const [meta] = await this.bucket.file(object).getMetadata();
      return { size: Number(meta.size ?? 0) };
    } catch (e) {
      if ((e as { code?: number }).code === 404) return null;
      throw e;
    }
  }

  async readUrl(object: string, ttlSeconds: number) {
    const expiresAt = new Date(Date.now() + ttlSeconds * 1000);
    const [url] = await this.bucket
      .file(object)
      .getSignedUrl({ version: 'v4', action: 'read', expires: expiresAt });
    return { url, expiresAt };
  }

  async deletePrefix(prefix: string) {
    await this.bucket.deleteFiles({ prefix });
  }
}
