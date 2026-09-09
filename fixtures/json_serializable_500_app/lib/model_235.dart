import 'package:json_annotation/json_annotation.dart';

part 'model_235.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model235 {
  const Model235({required this.id, required this.value});

  final int id;
  final String value;

  factory Model235.fromJson(Map<String, dynamic> json) =>
      _$Model235FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model235ToJson(this);
}
