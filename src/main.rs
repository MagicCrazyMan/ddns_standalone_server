use actix_web::{get, http::header::ContentType, App, HttpRequest, HttpResponse, HttpServer};

#[get("/ip")]
async fn ip(req: HttpRequest) -> HttpResponse {
    let peer_ip = req.peer_addr().map(|addr| addr.ip().to_canonical().to_string());

    match peer_ip {
        Some(ip) => HttpResponse::Ok()
            .insert_header(ContentType::plaintext())
            .body(ip),
        None => HttpResponse::BadRequest().finish(),
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    HttpServer::new(|| App::new().service(ip))
        .bind("[::0]:9080")?
        .run()
        .await
}
