import 'package:json_annotation/json_annotation.dart';

part 'model_023.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model023 {
  const Model023({required this.id, required this.value});

  final int id;
  final String value;

  factory Model023.fromJson(Map<String, dynamic> json) =>
      _$Model023FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model023ToJson(this);
}
