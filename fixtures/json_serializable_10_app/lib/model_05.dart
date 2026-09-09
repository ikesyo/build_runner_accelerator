import 'package:json_annotation/json_annotation.dart';

part 'model_05.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model05 {
  const Model05({required this.id, required this.value});

  final int id;
  final String value;

  factory Model05.fromJson(Map<String, dynamic> json) =>
      _$Model05FromJson(json);

  Map<String, dynamic> toJson() => _$Model05ToJson(this);
}
