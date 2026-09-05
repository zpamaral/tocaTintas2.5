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
//  ZPAirPlay.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 12/11/2026.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Enviada no thread principal sempre que a lista de aparelhos muda: um que
/// acabou de resolver, ou um que desapareceu da rede. Notificações seguidas são
/// juntas numa só, portanto quem a recebe pode redesenhar à vontade. O objecto
/// é a instância de ZPAirPlay que a enviou.
extern NSNotificationName const kZPAirPlayDispositivosMudaram;

/// Um aparelho AirPlay já resolvido. É imutável de propósito: quem o segura
/// durante uma selecção não vê o endereço mudar por baixo.
@interface ZPAparelhoAirPlay : NSObject

/// O nome que o dono deu ao aparelho, já sem o prefixo do MAC que o mDNS
/// antepõe («Apple TV (NAD)», não «A0EDCDE18416@Apple TV (NAD)»).
@property (nonatomic, readonly) NSString *nome;

/// Endereço IPv4 em texto, tal como o raop_play o quer na linha de comando.
@property (nonatomic, readonly) NSString *ip;

/// Porta RAOP, em texto pela mesma razão.
@property (nonatomic, readonly) NSString *porta;

/// Nome do anfitrião («Apple-TV-NAD.local.»). Não é usado para ligar seja o que
/// for; serve para o registo fazer sentido a quem esteja a depurar.
@property (nonatomic, readonly) NSString *anfitriao;

@end

/// Descoberta dos receptores AirPlay na rede local.
///
/// Assenta no NSNetServiceBrowser, que trata do mDNS todo e entrega os eventos
/// no thread principal. A versão anterior desta classe lançava `dns-sd -B`, um
/// `dns-sd -L` por aparelho e um `ping` por endereço, e passava o resultado
/// entre eles por dois ficheiros de texto no Application Support — o que trazia
/// três corridas: o ficheiro dos nomes era reescrito por cada pedaço de saída do
/// `dns-sd -B` (e o segundo pedaço apagava os aparelhos do primeiro), o
/// `dns-sd -L` era morto ao primeiro pedaço lido, muitas vezes antes de a linha
/// do endereço ter chegado, e as várias buscas escreviam no mesmo ficheiro sem
/// fecho nenhum. Um aparelho perdido por qualquer destas vias ficava marcado
/// como «já visto» e nunca mais era procurado.
///
/// Aqui não há ficheiros, nem subprocessos, nem lista negra: a lista vive em
/// memória, muda por evento, e um aparelho que falhe a resolução volta a ser
/// tentado — e, se desistirmos dele, basta que se anuncie outra vez para
/// recomeçar do zero.
///
/// Tudo nesta classe se usa a partir do thread principal.
@interface ZPAirPlay : NSObject

/// Os aparelhos resolvidos, por ordem alfabética. Um aparelho só aparece aqui
/// depois de ter endereço e porta, portanto tudo o que esta lista tem é
/// utilizável de imediato.
@property (nonatomic, readonly) NSArray<ZPAparelhoAirPlay *> *dispositivos;

- (void)startDiscovery;
- (void)stopDiscovery;

/// O aparelho com este nome, ou nil se desapareceu da rede ou ainda não
/// resolveu. Devolver nil é a resposta certa a «este nome ainda serve?», e é o
/// que permite à interface recusar uma selecção em vez de a aceitar em silêncio.
- (nullable ZPAparelhoAirPlay *)dispositivoComNome:(NSString *)nome;

@end

NS_ASSUME_NONNULL_END
