#AWS #Bedrock #GenerativeAI #Serverless #AWSLambda

*Build an AI Resume Scorer on AWS (Bedrock + Lambda + SQS)*

Score any resume against a job posting using a fully serverless, event-driven pipeline on AWS — provisioned with Terraform and deployed with a single script. Users sign in with Cognito, upload a resume, paste a job URL or description, and a queue-driven worker invokes Amazon Bedrock's Claude Haiku model to extract job metadata and return a 0–100 compatibility score with a written Strengths and Weaknesses analysis.

In this project we build an asynchronous AI scoring pipeline from scratch — the API returns immediately with a submitted status, SQS decouples the slow Bedrock inference call from the API response, and a worker Lambda handles URL fetching, HTML parsing, and two sequential Bedrock calls. The whole thing runs without a single EC2 instance.

WHAT YOU'LL LEARN
• Invoking Amazon Bedrock text models (Claude Haiku) from Lambda for multi-step AI pipelines
• Using SQS to decouple a slow AI inference call from a synchronous API response
• Fetching and parsing job posting HTML with BeautifulSoup before sending to Bedrock
• Implementing PKCE OAuth2 Authorization Code flow with Cognito in a static SPA
• Attaching a JWT authorizer to API Gateway HTTP API v2
• Single-table DynamoDB design with composite keys for per-user data isolation
• Storing and retrieving user content (resumes, analyses, notes) from private S3 paths
• Parameterizing a Bedrock model via bedrock-config.sh for easy model swapping

INFRASTRUCTURE DEPLOYED
• Cognito User Pool with Hosted UI domain and SPA app client (PKCE, no secret)
• API Gateway HTTP API with JWT authorizer (validates against Cognito JWKS)
• API Lambda (Python 3.11, handler.py): routes /resumes and /jobs endpoint families
• Worker Lambda (Python 3.11, worker.py, 512 MB, 300 s timeout) triggered by SQS
• SQS queue (job-requests, visibility timeout 1800 s) + dead-letter queue
• DynamoDB table (PAY_PER_REQUEST, PK=USER#<id>, SK=RESUME#<id> or JOB#<id>)
• S3 frontend bucket (public SPA hosting) + S3 backend bucket (private, SSE-AES256)
• IAM roles with least-privilege access to DynamoDB, S3, SQS, Bedrock, and CloudWatch

GitHub
https://github.com/mamonaco1973/aws-resume-app

README
https://github.com/mamonaco1973/aws-resume-app/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:21 Architecture
00:59 Build the Code
01:16 Build Results
01:52 Demo
