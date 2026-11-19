if ($null -eq ('ClcReleaseTests.RecordingHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace ClcReleaseTests {
    public sealed class ResponseSpec {
        public int StatusCode;
        public string Location;
        public HttpContent Content;
    }

    public sealed class RecordingHandler : HttpMessageHandler {
        public readonly List<string> RequestUris = new List<string>();
        public readonly List<string> AuthorizationValues = new List<string>();
        public readonly List<string> AcceptValues = new List<string>();
        public readonly List<string> RequestMethods = new List<string>();
        public readonly Queue<ResponseSpec> Responses = new Queue<ResponseSpec>();

        public void Enqueue(int statusCode, string location, byte[] body) {
            EnqueueContent(statusCode, location, new ByteArrayContent(body ?? Array.Empty<byte>()));
        }

        public void EnqueueContent(int statusCode, string location, HttpContent content) {
            Responses.Enqueue(new ResponseSpec { StatusCode = statusCode, Location = location, Content = content });
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
            RequestUris.Add(request.RequestUri.AbsoluteUri);
            AuthorizationValues.Add(request.Headers.Authorization == null ? null : request.Headers.Authorization.ToString());
            AcceptValues.Add(request.Headers.Accept.ToString());
            RequestMethods.Add(request.Method.Method);
            if (Responses.Count == 0) throw new InvalidOperationException("No response was queued for the HTTP request.");
            ResponseSpec item = Responses.Dequeue();
            HttpResponseMessage response = new HttpResponseMessage((HttpStatusCode)item.StatusCode);
            response.Content = item.Content;
            if (!String.IsNullOrEmpty(item.Location)) response.Headers.Location = new Uri(item.Location, UriKind.RelativeOrAbsolute);
            return Task.FromResult(response);
        }
    }
}
'@ -ErrorAction Stop
}
