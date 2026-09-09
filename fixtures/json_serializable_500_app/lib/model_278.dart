import 'package:json_annotation/json_annotation.dart';

part 'model_278.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model278 {
  const Model278({required this.id, required this.value});

  final int id;
  final String value;

  factory Model278.fromJson(Map<String, dynamic> json) =>
      _$Model278FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model278ToJson(this);
}
