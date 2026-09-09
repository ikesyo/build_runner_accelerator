import 'package:json_annotation/json_annotation.dart';

part 'model_069.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model069 {
  const Model069({required this.id, required this.value});

  final int id;
  final String value;

  factory Model069.fromJson(Map<String, dynamic> json) =>
      _$Model069FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model069ToJson(this);
}
