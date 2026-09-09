import 'package:json_annotation/json_annotation.dart';

part 'model_206.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model206 {
  const Model206({required this.id, required this.value});

  final int id;
  final String value;

  factory Model206.fromJson(Map<String, dynamic> json) =>
      _$Model206FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model206ToJson(this);
}
