/**
 * Mesh map export schema (GeoJSON FeatureCollection + export envelope).
 * CRS: EPSG:4326 — coordinates are [longitude, latitude].
 */

export interface MeshExportImage {
  present: boolean;
  mimeType?: string;
  url?: string;
  sha256?: string;
  width?: number;
  height?: number;
}

export interface MeshExportFeatureProperties {
  kind?: string;
  category?: string;
  title?: string;
  description?: string;
  createdAt?: string;
  senderId?: string;
  senderName?: string;
  confidence?: number;
  upVotes?: number;
  downVotes?: number;
  image?: MeshExportImage;
  [key: string]: unknown;
}

export interface MeshExportPointFeature {
  type: "Feature";
  id?: string;
  geometry: {
    type: "Point";
    coordinates: [number, number]; // [lng, lat]
  };
  properties: MeshExportFeatureProperties;
}

export interface MeshExportFeatureCollection {
  type: "FeatureCollection";
  features: MeshExportPointFeature[];
}

export interface MeshExportEnvelope {
  id: string;
  createdAt: string;
  crs: string;
  featureCollection: MeshExportFeatureCollection;
}

/** Root document: { export: MeshExportEnvelope } */
export interface MeshExportDocument {
  export: MeshExportEnvelope;
}
