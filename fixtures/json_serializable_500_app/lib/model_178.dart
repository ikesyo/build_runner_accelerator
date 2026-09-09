import 'package:json_annotation/json_annotation.dart';

part 'model_178.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model178 {
  const Model178({required this.id, required this.value});

  final int id;
  final String value;

  factory Model178.fromJson(Map<String, dynamic> json) =>
      _$Model178FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model178ToJson(this);
}
