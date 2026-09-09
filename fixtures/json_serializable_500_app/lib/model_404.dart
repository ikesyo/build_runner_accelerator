import 'package:json_annotation/json_annotation.dart';

part 'model_404.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model404 {
  const Model404({required this.id, required this.value});

  final int id;
  final String value;

  factory Model404.fromJson(Map<String, dynamic> json) =>
      _$Model404FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model404ToJson(this);
}
