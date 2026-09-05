/*
Copyright (c) 2026 Zé Pedro do Amaral <amaral@mac.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
//
//  ZPAirPlay.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 12/11/2026.
//

#import "ZPAirPlay.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>

NSNotificationName const kZPAirPlayDispositivosMudaram = @"kZPAirPlayDispositivosMudaram";

/// Quanto tempo se espera por cada resolução. Cinco segundos são muito para uma
/// rede local — o Apple TV desta casa resolve em dezenas de milissegundos —, mas
/// um aparelho a acordar do sono demora, e desistir cedo custa mais do que
/// esperar.
static const NSTimeInterval kZPTempoLimiteResolucao = 5.0;

/// Quantas vezes se insiste antes de largar um aparelho que não resolve. Não é
/// uma lista negra: largar só quer dizer que se deixa de esperar por ele. Se
/// voltar a anunciar-se, o browser chama outra vez o -didFindService: e a conta
/// recomeça.
static const NSInteger kZPMaximoTentativas = 3;

/// Pausa entre tentativas, para uma resolução que falhe de imediato não fazer
/// um ciclo apertado.
static const NSTimeInterval kZPEsperaEntreTentativas = 0.5;

#pragma mark - Utilitários

/// O mDNS anuncia os RAOP como «A0EDCDE18416@Apple TV (NAD)»: doze dígitos
/// hexadecimais com o endereço MAC, um arroba, e só depois o nome que o dono deu
/// ao aparelho. Tira-se o prefixo — mas só quando ele tem mesmo esse feitio, que
/// há receptores de terceiros cujo nome não o traz e outros que têm arrobas a
/// sério no meio.
static NSString *ZPNomeLegivel(NSString *nomeDoServico) {
    if (nomeDoServico.length <= 13) return nomeDoServico;
    if ([nomeDoServico characterAtIndex:12] != '@') return nomeDoServico;

    static NSCharacterSet *naoHexadecimais = nil;
    static dispatch_once_t umaVez;
    dispatch_once(&umaVez, ^{
        naoHexadecimais = [[NSCharacterSet characterSetWithCharactersInString:
                            @"0123456789abcdefABCDEF"] invertedSet];
    });

    NSString *prefixo = [nomeDoServico substringToIndex:12];
    if ([prefixo rangeOfCharacterFromSet:naoHexadecimais].location != NSNotFound) {
        return nomeDoServico;
    }

    NSString *resto = [nomeDoServico substringFromIndex:13];
    return resto.length > 0 ? resto : nomeDoServico;
}

/// O NSNetService entrega os endereços já resolvidos como `sockaddr` em bruto,
/// um por interface. O raop_play só come IPv4 na linha de comando, portanto o
/// que interessa é o primeiro AF_INET — e obtê-lo não custa processo nenhum,
/// muito menos um `ping`, que era como a versão anterior descobria o endereço e
/// que devolvia «N/A» sempre que o aparelho estava a dormir e não respondia ao
/// ICMP a tempo.
static NSString * _Nullable ZPPrimeiroIPv4(NSArray<NSData *> *enderecos) {
    for (NSData *dados in enderecos) {
        if (dados.length < sizeof(struct sockaddr_in)) continue;

        const struct sockaddr *sa = (const struct sockaddr *)dados.bytes;
        if (sa->sa_family != AF_INET) continue;

        const struct sockaddr_in *sin = (const struct sockaddr_in *)(const void *)sa;
        char texto[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &sin->sin_addr, texto, sizeof(texto)) == NULL) continue;

        return @(texto);
    }
    return nil;
}

#pragma mark - ZPAparelhoAirPlay

@interface ZPAparelhoAirPlay ()
- (instancetype)initComNome:(NSString *)nome
                         ip:(NSString *)ip
                      porta:(NSString *)porta
                  anfitriao:(NSString *)anfitriao;
@end

@implementation ZPAparelhoAirPlay

- (instancetype)initComNome:(NSString *)nome
                         ip:(NSString *)ip
                      porta:(NSString *)porta
                  anfitriao:(NSString *)anfitriao {
    self = [super init];
    if (self) {
        _nome = [nome copy];
        _ip = [ip copy];
        _porta = [porta copy];
        _anfitriao = [anfitriao copy];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ — %@:%@ (%@)>",
            NSStringFromClass(self.class), self.nome, self.ip, self.porta, self.anfitriao];
}

- (BOOL)isEqual:(id)outro {
    if (self == outro) return YES;
    if (![outro isKindOfClass:[ZPAparelhoAirPlay class]]) return NO;
    ZPAparelhoAirPlay *aquele = outro;
    return [self.nome isEqualToString:aquele.nome]
        && [self.ip isEqualToString:aquele.ip]
        && [self.porta isEqualToString:aquele.porta];
}

- (NSUInteger)hash {
    return self.nome.hash ^ self.ip.hash ^ self.porta.hash;
}

@end

#pragma mark - ZPAirPlay

@interface ZPAirPlay () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (nonatomic, strong, nullable) NSNetServiceBrowser *browser;

/// Os serviços que estão a resolver. Segurá-los aqui é obrigatório: o browser
/// larga-os assim que o -didFindService: retorna, e um NSNetService libertado a
/// meio da resolução nunca chega a chamar o delegado. É a armadilha clássica
/// desta API.
@property (nonatomic, strong) NSMutableSet<NSNetService *> *porResolver;

/// Tentativas já gastas em cada serviço, pelo nome do serviço (o de rede, com o
/// prefixo do MAC, que é o que identifica o anúncio).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *tentativas;

/// Os aparelhos já resolvidos, pelo nome legível.
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZPAparelhoAirPlay *> *porNome;

/// Uma notificação já agendada para o fim deste ciclo do run loop, para uma
/// rajada de eventos não dar uma rajada de redesenhos.
@property (nonatomic, assign) BOOL notificacaoAgendada;

@end

@implementation ZPAirPlay

#pragma mark Ciclo de vida

- (instancetype)init {
    self = [super init];
    if (self) {
        _porResolver = [NSMutableSet set];
        _tentativas = [NSMutableDictionary dictionary];
        _porNome = [NSMutableDictionary dictionary];
        [ZPAirPlay apagarFicheirosDaDescobertaAntiga];
    }
    return self;
}

- (void)dealloc {
    [self pararTudo];
}

/// A descoberta antiga guardava a lista em AirPlay_IP.txt e AirPlay_BonJour.txt
/// e voltava a lê-los para saber o endereço de cada aparelho. Já ninguém os lê;
/// ficariam ali a enganar quem fosse depurar isto daqui a um ano.
+ (void)apagarFicheirosDaDescobertaAntiga {
    static dispatch_once_t umaVez;
    dispatch_once(&umaVez, ^{
        NSString *pasta = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                               NSUserDomainMask, YES).firstObject
                           stringByAppendingPathComponent:@"tocaTintas"];
        if (!pasta) return;
        for (NSString *nome in @[@"AirPlay_IP.txt", @"AirPlay_BonJour.txt"]) {
            [[NSFileManager defaultManager] removeItemAtPath:
             [pasta stringByAppendingPathComponent:nome] error:NULL];
        }
    });
}

#pragma mark Descoberta

- (void)startDiscovery {
    if (self.browser) {
        // Já está à procura. O browser não precisa de ser reiniciado para dar
        // por aparelhos novos — ele avisa sozinho.
        return;
    }

    self.browser = [[NSNetServiceBrowser alloc] init];
    self.browser.delegate = self;

    // Modos comuns, e não o modo por omissão: sem isto os eventos deixam de
    // chegar enquanto um menu ou um popover está a seguir o rato, que é
    // exactamente o momento em que a lista tem de estar viva.
    [self.browser scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.browser searchForServicesOfType:@"_raop._tcp." inDomain:@"local."];

    #ifdef DEBUG
    NSLog(@"[AirPlay] Descoberta iniciada (_raop._tcp em local.).");
    #endif
}

- (void)stopDiscovery {
    [self pararTudo];
    [self.porNome removeAllObjects];
    [self notificarMudanca];

    #ifdef DEBUG
    NSLog(@"[AirPlay] Descoberta parada.");
    #endif
}

- (void)pararTudo {
    [self.browser stop];
    self.browser.delegate = nil;
    self.browser = nil;

    for (NSNetService *servico in self.porResolver) {
        servico.delegate = nil;
        [servico stop];
    }
    [self.porResolver removeAllObjects];
    [self.tentativas removeAllObjects];
}

#pragma mark Consulta

- (NSArray<ZPAparelhoAirPlay *> *)dispositivos {
    return [self.porNome.allValues sortedArrayUsingComparator:
            ^NSComparisonResult(ZPAparelhoAirPlay *um, ZPAparelhoAirPlay *outro) {
        return [um.nome localizedCaseInsensitiveCompare:outro.nome];
    }];
}

- (ZPAparelhoAirPlay *)dispositivoComNome:(NSString *)nome {
    if (nome.length == 0) return nil;
    return self.porNome[nome];
}

#pragma mark Notificação

- (void)notificarMudanca {
    if (self.notificacaoAgendada) return;
    self.notificacaoAgendada = YES;

    __weak typeof(self) fraco = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(fraco) forte = fraco;
        if (!forte) return;
        forte.notificacaoAgendada = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:kZPAirPlayDispositivosMudaram
                                                            object:forte];
    });
}

#pragma mark Delegado do browser

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)servico
               moreComing:(BOOL)maisAVir {
    #ifdef DEBUG
    NSLog(@"[AirPlay] Encontrado «%@»; a resolver.", servico.name);
    #endif

    self.tentativas[servico.name] = @0;
    [self resolver:servico];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)servico
               moreComing:(BOOL)maisAVir {
    NSString *nome = ZPNomeLegivel(servico.name);

    #ifdef DEBUG
    NSLog(@"[AirPlay] «%@» desapareceu da rede.", servico.name);
    #endif

    [self esquecerServicoChamado:servico.name];

    if (self.porNome[nome]) {
        [self.porNome removeObjectForKey:nome];
        [self notificarMudanca];
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
             didNotSearch:(NSDictionary<NSString *, NSNumber *> *)erro {
    NSLog(@"[AirPlay] A busca não arrancou: %@. Não vai haver aparelhos na lista.", erro);
    self.browser = nil;
}

#pragma mark Resolução

- (void)resolver:(NSNetService *)servico {
    servico.delegate = self;
    [self.porResolver addObject:servico];
    [servico scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [servico resolveWithTimeout:kZPTempoLimiteResolucao];
}

- (void)netServiceDidResolveAddress:(NSNetService *)servico {
    NSString *ip = ZPPrimeiroIPv4(servico.addresses);

    if (ip == nil || servico.port <= 0) {
        // Resolveu, mas sem nada que se aproveite: só IPv6, ou uma porta que não
        // faz sentido. Vale a pena insistir — os anúncios chegam interface a
        // interface e o IPv4 pode vir no seguinte.
        #ifdef DEBUG
        NSLog(@"[AirPlay] «%@» resolveu sem IPv4 utilizável (porta %ld).",
              servico.name, (long)servico.port);
        #endif
        [self tentarOutraVez:servico];
        return;
    }

    NSString *nome = ZPNomeLegivel(servico.name);
    ZPAparelhoAirPlay *aparelho =
        [[ZPAparelhoAirPlay alloc] initComNome:nome
                                            ip:ip
                                         porta:[NSString stringWithFormat:@"%ld", (long)servico.port]
                                     anfitriao:servico.hostName ?: @""];

    BOOL mudou = ![aparelho isEqual:self.porNome[nome]];
    self.porNome[nome] = aparelho;

    // Resolvido: já não é preciso segurar o serviço. Se o endereço mudar, o
    // aparelho volta a anunciar-se e passamos outra vez por aqui.
    [self esquecerServicoChamado:servico.name];

    #ifdef DEBUG
    NSLog(@"[AirPlay] %@", aparelho);
    #endif

    if (mudou) [self notificarMudanca];
}

- (void)netService:(NSNetService *)servico
     didNotResolve:(NSDictionary<NSString *, NSNumber *> *)erro {
    #ifdef DEBUG
    NSLog(@"[AirPlay] «%@» não resolveu: %@", servico.name, erro);
    #endif
    [self tentarOutraVez:servico];
}

- (void)tentarOutraVez:(NSNetService *)servico {
    NSString *nomeDoServico = servico.name;
    NSInteger gastas = self.tentativas[nomeDoServico].integerValue + 1;

    if (gastas >= kZPMaximoTentativas) {
        NSLog(@"[AirPlay] Desisti de resolver «%@» ao fim de %ld tentativas. "
               "Volta à lista se se anunciar outra vez.", nomeDoServico, (long)gastas);
        [self esquecerServicoChamado:nomeDoServico];
        return;
    }

    self.tentativas[nomeDoServico] = @(gastas);

    __weak typeof(self) fraco = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kZPEsperaEntreTentativas * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(fraco) forte = fraco;
        // Entretanto pode ter desaparecido da rede, ou a descoberta ter parado.
        if (!forte || ![forte.porResolver containsObject:servico]) return;
        [servico resolveWithTimeout:kZPTempoLimiteResolucao];
    });
}

/// O NSNetService que chega no -didRemoveService: não é forçosamente o mesmo
/// objecto que chegou no -didFindService:, por isso a correspondência faz-se
/// pelo nome do serviço e não por identidade.
- (void)esquecerServicoChamado:(NSString *)nomeDoServico {
    NSMutableSet<NSNetService *> *aTirar = [NSMutableSet set];
    for (NSNetService *servico in self.porResolver) {
        if ([servico.name isEqualToString:nomeDoServico]) {
            servico.delegate = nil;
            [servico stop];
            [aTirar addObject:servico];
        }
    }
    [self.porResolver minusSet:aTirar];
    [self.tentativas removeObjectForKey:nomeDoServico];
}

@end
