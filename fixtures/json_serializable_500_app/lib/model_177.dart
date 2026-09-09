import 'package:json_annotation/json_annotation.dart';

part 'model_177.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model177 {
  const Model177({required this.id, required this.value});

  final int id;
  final String value;

  factory Model177.fromJson(Map<String, dynamic> json) =>
      _$Model177FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model177ToJson(this);
}
