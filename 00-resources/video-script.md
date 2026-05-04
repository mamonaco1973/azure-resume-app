# Video Script — Secure your Serverless API in AWS (Cognito + API Gateway)

---

## Introduction

[ Show LinkedIn scoring ]

Most AI resume tools score one job at a time.

[ Other Job Platforms ]

But real job searches don’t work like that — you’re tracking dozens across multiple sites.

[ Dashboard ]

In this project, we build an AI-powered dashboard to upload your resume, track applications, and score every job in one place.

[ B Roll ]

Follow along and build a complete serverless AI app on AWS using Bedrock, Lambda, and SQS.

---

## Architecture

[ Full diagram ]

"Let's walk through the architecture before we build."

[ Diagram then Congito ]

First, the user signs in to the web application using Cognito.

[ Manage Resumes Dialog ]

Before scoring any jobs, you upload your resume.

[ Upload Flow ]

The resume is stored in the application’s S3 bucket.

[  Score Dialog ]

Now you can submit a job for scoring — either by URL or raw text.

[ Highlight Dynamo DB]

When you click Submit, a job record is created in DynamoDB

[ Highlight SQS queue ]

At the same time, a message is sent to the scoring queue.

[ Highlight Lambda ]

That queue triggers the worker Lambda.

[ Show bedrock ]

The worker calls Bedrock to extract the job details and score the resume.

[ Show S3 Media Bucket]

The scoring results and analysis are written back to S3.

[ Final Dynamo DB State]

The job status is updated in DynamoDB.

[ Show final result ]

The application refreshes and displays the completed results.

---

## Build Results

[ Show Buckets ]

Two S3 buckets are created for this project.

[ Web Bucket ]

The first hosts the public web application.

[ Media Bucket]

The second stores résumé  and scoring results.

[ Show Identity ]

Authentication is handled by Cognito and enforced by API Gateway.

[Show Lambda Functions] 

The API is implemented with Python Lambda functions.

[ SQS ]

Job scoring is driven by an SQS queue.

[ Fire Store ]

DynamoDB tracks the state of each scoring job.

[ Show Worker Function ]

When a message is received, the worker Lambda calls Bedrock to extract and score the job.

[ Show Media Bucket ]

The results are written back to S3.

[ Show DynamoDB completion record]

The job status is updated to “scored”.

[ Show Web Application ]

The application refreshes and displays the results.

---

## Demo

[ Time 0 ]

"Navigate to the web application URL"

[ Clicking Login — Cognito Hosted UI opens ]

"Sign in using Cognito."

[ Choose Manage Resumes button ]

Once signed in, open Manage Resumes

[ Show Manage Resume Dialog ]

Paste your resume and click Create Resume.

[ Select Score New Job button]

Now select Score New Job.

[ Show Score New Job Dialog ]

Choose LinkedIn as the source and enter one or more job IDs.

[ Show Submit Button ]

Click Submit to start scoring.

[ Show Status ]

The dashboard updates as jobs move from submitted to scoring.

All jobs are tracked here with their current status and scores.

[ Show Results ]

Click Open to view the full analysis.

[ Show bad job ]

This one’s clearly not a good fit. 

[Show better job ]

Now here’s a role that aligns much better.

---
