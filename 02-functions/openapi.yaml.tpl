swagger: "2.0"
info:
  title: Resume Scorer API
  version: "1.0"
host: "placeholder.apigateway.${project_id}.cloud.goog"
schemes:
  - https
produces:
  - application/json

securityDefinitions:
  firebase:
    authorizationUrl: ""
    flow: "implicit"
    type: "oauth2"
    x-google-issuer: "https://securetoken.google.com/${project_id}"
    x-google-jwks_uri: "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
    x-google-audiences: "${project_id}"

x-google-backend:
  address: ${api_url}
  protocol: h2
  jwt_audience: ${api_url}

paths:

  /resumes:
    options:
      operationId: corsResumes
      parameters: []
      responses:
        "204":
          description: CORS preflight
    get:
      operationId: listResumes
      security:
        - firebase: []
      parameters: []
      responses:
        "200":
          description: OK
    post:
      operationId: createResume
      security:
        - firebase: []
      parameters:
        - in: body
          name: body
          schema:
            type: object
      responses:
        "200":
          description: OK

  /resumes/{id}:
    options:
      operationId: corsResumeById
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "204":
          description: CORS preflight
    get:
      operationId: getResume
      security:
        - firebase: []
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "200":
          description: OK
    put:
      operationId: updateResume
      security:
        - firebase: []
      parameters:
        - in: path
          name: id
          required: true
          type: string
        - in: body
          name: body
          schema:
            type: object
      responses:
        "200":
          description: OK
    delete:
      operationId: deleteResume
      security:
        - firebase: []
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "200":
          description: OK

  /jobs:
    options:
      operationId: corsJobs
      parameters: []
      responses:
        "204":
          description: CORS preflight
    get:
      operationId: listJobs
      security:
        - firebase: []
      parameters: []
      responses:
        "200":
          description: OK
    post:
      operationId: createJob
      security:
        - firebase: []
      parameters:
        - in: body
          name: body
          schema:
            type: object
      responses:
        "200":
          description: OK

  /jobs/{id}:
    options:
      operationId: corsJobById
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "204":
          description: CORS preflight
    get:
      operationId: getJob
      security:
        - firebase: []
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "200":
          description: OK
    delete:
      operationId: deleteJob
      security:
        - firebase: []
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "200":
          description: OK

  /jobs/{id}/notes:
    options:
      operationId: corsJobNotes
      parameters:
        - in: path
          name: id
          required: true
          type: string
      responses:
        "204":
          description: CORS preflight
    patch:
      operationId: updateJobNotes
      security:
        - firebase: []
      parameters:
        - in: path
          name: id
          required: true
          type: string
        - in: body
          name: body
          schema:
            type: object
      responses:
        "200":
          description: OK
